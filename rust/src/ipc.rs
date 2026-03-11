//! JARVIS IPC Client
//!
//! Runs a background thread that connects to /tmp/jarvis.sock.
//! Auto-reconnects every 2s on disconnect.
//!
//! IPC thread  -> Qt thread : event_rx  (mpsc Receiver<IpcEvent>)
//! Qt thread   -> IPC thread: command_tx (mpsc Sender<IpcCommand>)

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::thread;
use std::time::Duration;

pub const SOCKET_PATH: &str = "/tmp/jarvis.sock";
const RECONNECT_DELAY: Duration = Duration::from_secs(2);
const COMMAND_POLL: Duration = Duration::from_millis(50);

#[derive(Debug, Clone)]
pub enum IpcEvent {
    Connected,
    Disconnected,
    State(String),
    ResponseChunk { content: String, done: bool },
    WakeWordDetected,
    Error(String),
}

#[derive(Debug)]
pub enum IpcCommand {
    SendMessage(String),
    StartListening,
    StopListening,
    Shutdown,
}

pub struct IpcClient {
    event_rx: Receiver<IpcEvent>,
    command_tx: Sender<IpcCommand>,
}

impl IpcClient {
    pub fn new() -> Self {
        let (event_tx, event_rx) = mpsc::channel::<IpcEvent>();
        let (command_tx, command_rx) = mpsc::channel::<IpcCommand>();

        thread::Builder::new()
            .name("jarvis-ipc".into())
            .spawn(move || ipc_thread(event_tx, command_rx))
            .expect("failed to spawn IPC thread");

        Self { event_rx, command_tx }
    }

    pub fn try_recv(&self) -> Option<IpcEvent> {
        match self.event_rx.try_recv() {
            Ok(event) => Some(event),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => Some(IpcEvent::Disconnected),
        }
    }

    pub fn send_message(&self, content: String) {
        let _ = self.command_tx.send(IpcCommand::SendMessage(content));
    }

    pub fn start_listening(&self) {
        let _ = self.command_tx.send(IpcCommand::StartListening);
    }

    pub fn stop_listening(&self) {
        let _ = self.command_tx.send(IpcCommand::StopListening);
    }
}

impl Default for IpcClient {
    fn default() -> Self { Self::new() }
}

fn ipc_thread(event_tx: Sender<IpcEvent>, command_rx: Receiver<IpcCommand>) {
    loop {
        match UnixStream::connect(SOCKET_PATH) {
            Ok(stream) => {
                let _ = event_tx.send(IpcEvent::Connected);
                run_connected(&stream, &event_tx, &command_rx);
                let _ = event_tx.send(IpcEvent::Disconnected);
            }
            Err(_) => {}
        }

        match command_rx.try_recv() {
            Ok(IpcCommand::Shutdown) | Err(TryRecvError::Disconnected) => return,
            _ => {}
        }

        thread::sleep(RECONNECT_DELAY);
    }
}

fn run_connected(
    stream: &UnixStream,
    event_tx: &Sender<IpcEvent>,
    command_rx: &Receiver<IpcCommand>,
) {
    let read_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => { eprintln!("jarvis-ipc: clone failed: {e}"); return; }
    };

    let (read_tx, read_rx) = mpsc::channel::<Option<IpcEvent>>();
    thread::Builder::new()
        .name("jarvis-ipc-reader".into())
        .spawn(move || {
            let reader = BufReader::new(read_stream);
            for line in reader.lines() {
                match line {
                    Ok(l) if !l.is_empty() => {
                        if read_tx.send(Some(parse_daemon_message(&l))).is_err() { break; }
                    }
                    Ok(_) => {}
                    Err(_) => { let _ = read_tx.send(None); break; }
                }
            }
        })
        .expect("failed to spawn reader thread");

    let mut write_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => { eprintln!("jarvis-ipc: write clone failed: {e}"); return; }
    };

    loop {
        loop {
            match read_rx.try_recv() {
                Ok(Some(event)) => { if event_tx.send(event).is_err() { return; } }
                Ok(None) => return,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return,
            }
        }

        match command_rx.recv_timeout(COMMAND_POLL) {
            Ok(IpcCommand::SendMessage(content)) => {
                let msg = format!("{}\n", serde_json::json!({"type":"message","content":content}));
                if write_stream.write_all(msg.as_bytes()).is_err() { return; }
            }
            Ok(IpcCommand::StartListening) => {
                let msg = format!("{}\n", serde_json::json!({"type":"start_listening"}));
                if write_stream.write_all(msg.as_bytes()).is_err() { return; }
            }
            Ok(IpcCommand::StopListening) => {
                let msg = format!("{}\n", serde_json::json!({"type":"stop_listening"}));
                let _ = write_stream.write_all(msg.as_bytes());
            }
            Ok(IpcCommand::Shutdown) => return,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
    }
}

fn parse_daemon_message(line: &str) -> IpcEvent {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
        return IpcEvent::Error(format!("invalid JSON: {line}"));
    };

    match value.get("type").and_then(|t| t.as_str()) {
        Some("state") => IpcEvent::State(
            value.get("state").and_then(|s| s.as_str()).unwrap_or("idle").to_string()
        ),
        Some("response") => IpcEvent::ResponseChunk {
            content: value.get("content").and_then(|c| c.as_str()).unwrap_or("").to_string(),
            done:    value.get("done").and_then(|d| d.as_bool()).unwrap_or(true),
        },
        Some("wake_word_detected") => IpcEvent::WakeWordDetected,
        Some("error") => IpcEvent::Error(
            value.get("message").and_then(|m| m.as_str()).unwrap_or("Unknown error").to_string()
        ),
        Some("ping") | Some("pong") => IpcEvent::State("idle".into()),
        other => IpcEvent::Error(format!("unknown type: {other:?}")),
    }
}
