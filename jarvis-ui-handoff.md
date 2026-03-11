# jarvis-ui — Claude Code Handoff

## Project Overview

This is the JARVIS OS chat UI — a Rust + CXX-Qt application providing a
ChatGPT-style text interface for the JARVIS daemon. It communicates with the
Python daemon over a bidirectional Unix socket using newline-delimited JSON.

**Stack:** Rust · CXX-Qt 0.7 · Qt6/QML · Python asyncio  
**Socket:** `/tmp/jarvis.sock` (JSON-L, bidirectional)  
**Theme:** JARVIS cyan (`#00c8ff` / `#00e5ff`) on dark navy

---

## Repo Structure to Create

```
jarvis-ui/
├── LICENSE                        ← MIT
├── README.md                      ← (generate a basic one)
├── python/
│   ├── ipc_server.py              ← Async Unix socket server (daemon side)
│   └── main_integration.py        ← How to wire ipc_server into main.py
└── rust/
    ├── Cargo.toml
    ├── build.rs
    ├── resources.qrc
    ├── src/
    │   ├── main.rs
    │   ├── ipc.rs
    │   └── bridge.rs
    └── qml/
        ├── Main.qml
        ├── ChatView.qml
        ├── MessageBubble.qml
        ├── InputBar.qml
        └── StatusIndicator.qml
```

---

## IPC Protocol Reference

```
Client → Daemon
  {"type": "message",        "content": "turn off wifi"}
  {"type": "start_listening"}
  {"type": "stop_listening"}
  {"type": "ping"}

Daemon → All Clients
  {"type": "state",          "state": "idle|listening|processing|speaking|offline"}
  {"type": "response",       "content": "...", "done": false}   ← streaming chunk
  {"type": "response",       "content": "",    "done": true}    ← stream finished
  {"type": "wake_word_detected"}
  {"type": "error",          "message": "..."}
  {"type": "pong"}
```

---

## File Contents

### `python/ipc_server.py`

```python
"""
JARVIS IPC Server
=================
Bidirectional Unix socket server for communicating with UI clients.
Protocol: Newline-delimited JSON (JSON-L)

Client → Daemon:
  {"type": "message", "content": "turn off wifi"}
  {"type": "start_listening"}
  {"type": "stop_listening"}
  {"type": "ping"}

Daemon → All Clients:
  {"type": "state", "state": "idle|listening|processing|speaking|offline"}
  {"type": "response", "content": "...", "done": false}   ← streaming chunk
  {"type": "response", "content": "", "done": true}       ← stream finished
  {"type": "wake_word_detected"}
  {"type": "error", "message": "..."}
  {"type": "pong"}
"""

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Callable, Optional, Set

logger = logging.getLogger("jarvis.ipc")

SOCKET_PATH = "/tmp/jarvis.sock"


class IPCServer:
    """
    Async Unix socket IPC server.

    Integrate into the JARVIS daemon like this:

        ipc = IPCServer(on_text_message=self.handle_text_input)
        await ipc.start()

        # Broadcast state changes from anywhere in the daemon:
        await ipc.set_state("processing")
        await ipc.send_response_chunk("Here is your answer...", done=False)
        await ipc.send_response_chunk("", done=True)
    """

    def __init__(self, on_text_message: Optional[Callable] = None):
        """
        Args:
            on_text_message: Async callable invoked when a UI client sends a
                             text message. Signature: async def fn(content: str)
        """
        self._on_text_message = on_text_message
        self._clients: Set[asyncio.StreamWriter] = set()
        self._server: Optional[asyncio.AbstractServer] = None
        self._current_state: str = "idle"

    # -------------------------------------------------------------------------
    # Lifecycle
    # -------------------------------------------------------------------------

    async def start(self) -> None:
        """Start listening on SOCKET_PATH. Call once at daemon startup."""
        socket_path = Path(SOCKET_PATH)

        # Remove stale socket file from a previous run
        if socket_path.exists():
            socket_path.unlink()

        self._server = await asyncio.start_unix_server(
            self._handle_client,
            path=SOCKET_PATH,
        )

        # Allow any local user to connect (jarvis user, live user, etc.)
        os.chmod(SOCKET_PATH, 0o666)

        logger.info(f"IPC server listening on {SOCKET_PATH}")

    async def stop(self) -> None:
        """Gracefully shut down the IPC server."""
        if self._server:
            self._server.close()
            await self._server.wait_closed()

        for writer in list(self._clients):
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

        self._clients.clear()
        logger.info("IPC server stopped")

    # -------------------------------------------------------------------------
    # Outbound – daemon → all UI clients
    # -------------------------------------------------------------------------

    async def set_state(self, state: str) -> None:
        """
        Broadcast a state change to all connected UI clients.

        Valid states: idle, listening, processing, speaking, offline
        """
        self._current_state = state
        await self._broadcast({"type": "state", "state": state})
        logger.debug(f"IPC state → {state}")

    async def send_response_chunk(self, content: str, done: bool = False) -> None:
        """
        Stream a response chunk to all connected UI clients.

        Call with done=False for each incremental chunk, then once with
        done=True (and empty content) to signal stream completion.
        """
        await self._broadcast({"type": "response", "content": content, "done": done})

    async def send_wake_word_detected(self) -> None:
        """Notify UI clients that the wake word was detected."""
        await self._broadcast({"type": "wake_word_detected"})

    async def send_error(self, message: str) -> None:
        """Broadcast an error message to all connected UI clients."""
        await self._broadcast({"type": "error", "message": message})

    # -------------------------------------------------------------------------
    # Internal
    # -------------------------------------------------------------------------

    async def _handle_client(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        addr = writer.get_extra_info("peername", "unknown")
        logger.info(f"IPC client connected: {addr}")
        self._clients.add(writer)

        # Send current state to newly connected client immediately
        try:
            await self._write(writer, {"type": "state", "state": self._current_state})
        except Exception:
            pass

        try:
            while True:
                try:
                    line = await asyncio.wait_for(reader.readline(), timeout=60.0)
                except asyncio.TimeoutError:
                    # Send a keep-alive ping
                    try:
                        await self._write(writer, {"type": "ping"})
                    except Exception:
                        break
                    continue

                if not line:
                    break  # Client disconnected

                line = line.strip()
                if not line:
                    continue

                try:
                    msg = json.loads(line.decode("utf-8"))
                    await self._process_message(msg, writer)
                except json.JSONDecodeError as e:
                    logger.warning(f"IPC invalid JSON from client: {e}")

        except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
            pass
        except Exception as e:
            logger.error(f"IPC client error: {e}", exc_info=True)
        finally:
            self._clients.discard(writer)
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
            logger.info(f"IPC client disconnected: {addr}")

    async def _process_message(
        self,
        msg: dict,
        writer: asyncio.StreamWriter,
    ) -> None:
        msg_type = msg.get("type")

        if msg_type == "message":
            content = msg.get("content", "").strip()
            if content and self._on_text_message:
                await self._on_text_message(content)

        elif msg_type == "start_listening":
            await self.set_state("listening")

        elif msg_type == "stop_listening":
            await self.set_state("idle")

        elif msg_type == "ping":
            try:
                await self._write(writer, {"type": "pong"})
            except Exception:
                pass

        else:
            logger.debug(f"IPC unknown message type: {msg_type}")

    async def _broadcast(self, message: dict) -> None:
        """Send a message to every connected client."""
        if not self._clients:
            return

        data = (json.dumps(message) + "\n").encode("utf-8")
        dead: Set[asyncio.StreamWriter] = set()

        for writer in list(self._clients):
            try:
                writer.write(data)
                await writer.drain()
            except Exception:
                dead.add(writer)

        self._clients -= dead

    @staticmethod
    async def _write(writer: asyncio.StreamWriter, message: dict) -> None:
        data = (json.dumps(message) + "\n").encode("utf-8")
        writer.write(data)
        await writer.drain()
```

---

### `python/main_integration.py`

```python
"""
JARVIS Daemon – IPC Integration Guide
======================================
This file shows the exact changes needed in jarvis/main.py (or wherever
your Jarvis class lives) to integrate the IPCServer.

Search for the TODO comments and apply the matching changes to your
existing main.py / Jarvis class.
"""

import asyncio
import logging

# ── TODO 1: import IPCServer at the top of your main.py ──────────────────────
from jarvis.ipc_server import IPCServer

logger = logging.getLogger("jarvis.main")


class Jarvis:
    """
    Example showing where to add IPC hooks in your existing Jarvis class.
    Only the relevant additions are shown; keep everything else as-is.
    """

    def __init__(self):
        # ── TODO 2: instantiate IPCServer ─────────────────────────────────────
        self.ipc = IPCServer(on_text_message=self.handle_text_input)

        # ... your existing __init__ code ...

    # ── TODO 3: start IPC server inside your async startup method ─────────────
    async def start(self):
        """Called once when the daemon starts."""
        await self.ipc.start()
        # ... your existing startup code (load models, etc.) ...

    # ── TODO 4: stop IPC server in your shutdown/cleanup method ───────────────
    async def stop(self):
        await self.ipc.stop()
        # ... your existing teardown code ...

    # ── TODO 5: add this method if it doesn't exist ───────────────────────────
    async def handle_text_input(self, content: str) -> None:
        """
        Called when a UI client sends a text message via the IPC socket.
        Wire this into the same code path your CLI / voice loop uses.
        """
        logger.info(f"IPC text input: {content!r}")

        try:
            await self.ipc.set_state("processing")

            # ── Replace this block with your actual LLM call ──────────────────
            # Streaming:
            #   async for chunk in self.llm.stream(content):
            #       await self.ipc.send_response_chunk(chunk, done=False)
            #   await self.ipc.send_response_chunk("", done=True)
            #
            # Non-streaming:
            #   response = await self.llm.query(content)
            #   await self.ipc.send_response_chunk(response, done=True)

            response = await self._query_llm(content)
            await self.ipc.send_response_chunk(response, done=True)

        except Exception as e:
            logger.error(f"Error processing text input: {e}", exc_info=True)
            await self.ipc.send_error(str(e))
        finally:
            await self.ipc.set_state("idle")

    # ── TODO 6: broadcast state changes from your existing voice loop ─────────
    #
    #   On wake-word detection:
    #       await self.ipc.send_wake_word_detected()
    #       await self.ipc.set_state("listening")
    #
    #   Before TTS / speaking:
    #       await self.ipc.set_state("speaking")
    #
    #   After TTS finishes:
    #       await self.ipc.set_state("idle")
    #
    #   Before querying the LLM:
    #       await self.ipc.set_state("processing")

    async def _query_llm(self, content: str) -> str:
        """Stub – replace with your real Ollama / LLM call."""
        raise NotImplementedError

    def listen_with_activation(self):
        asyncio.run(self._async_listen_loop())

    async def _async_listen_loop(self):
        await self.start()
        try:
            await asyncio.Event().wait()
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass
        finally:
            await self.stop()
```

---

### `rust/Cargo.toml`

```toml
[package]
name = "jarvis-ui"
version = "0.1.0"
edition = "2021"
description = "JARVIS OS – Chat UI (CXX-Qt)"

[[bin]]
name = "jarvis-ui"
path = "src/main.rs"

[dependencies]
cxx-qt     = "0.7"
cxx-qt-lib = { version = "0.7", features = ["full"] }
serde      = { version = "1", features = ["derive"] }
serde_json = "1"
chrono     = { version = "0.4", features = ["clock"] }

[build-dependencies]
cxx-qt-build = "0.7"

# Build requirements (Arch Linux):
#   sudo pacman -S qt6-base qt6-declarative cmake ninja rust
#
# Build:
#   cargo build --release
```

---

### `rust/build.rs`

```rust
use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    CxxQtBuilder::new()
        .file("src/bridge.rs")
        .qml_module(QmlModule {
            uri: "JarvisUI",
            version_major: 1,
            version_minor: 0,
            qml_files: &[
                "qml/Main.qml",
                "qml/ChatView.qml",
                "qml/MessageBubble.qml",
                "qml/InputBar.qml",
                "qml/StatusIndicator.qml",
            ],
            ..Default::default()
        })
        .build();
}
```

---

### `rust/src/main.rs`

```rust
mod bridge;
mod ipc;

use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QUrl, QString};

fn main() {
    let mut app = QGuiApplication::new();
    app.set_application_name(QString::from("JARVIS"));
    app.set_organization_name(QString::from("JarvisOS"));
    app.set_application_version(QString::from(env!("CARGO_PKG_VERSION")));

    let mut engine = QQmlApplicationEngine::default();
    engine.load(QUrl::from(QString::from("qrc:/qt/qml/JarvisUI/qml/Main.qml")));

    if engine.root_objects().is_empty() {
        eprintln!("jarvis-ui: failed to load Main.qml");
        std::process::exit(1);
    }

    app.exec();
}
```

---

### `rust/src/ipc.rs`

```rust
//! JARVIS IPC Client
//!
//! Runs a background thread that connects to /tmp/jarvis.sock.
//! Auto-reconnects every 2s on disconnect.
//!
//! IPC thread  → Qt thread : event_rx  (mpsc Receiver<IpcEvent>)
//! Qt thread   → IPC thread: command_tx (mpsc Sender<IpcCommand>)

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
```

---

### `rust/src/bridge.rs`

```rust
//! CXX-Qt bridge — exposes JarvisBridge as a QML element.
//!
//! QML usage:
//!   import JarvisUI 1.0
//!   JarvisBridge {
//!       id: bridge
//!       onUserMessageAdded: (content) => { ... }
//!       onJarvisStreamChunk: (content, done) => { ... }
//!   }
//!
//! A QTimer in Main.qml calls bridge.pollIpc() every 50 ms.

use std::pin::Pin;
use cxx_qt_lib::QString;
use crate::ipc::{IpcClient, IpcEvent};

#[cxx_qt::bridge]
pub mod ffi {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(QString, jarvis_state)]
        #[qproperty(bool, connected)]
        #[qproperty(bool, is_listening)]
        type JarvisBridge = super::JarvisBridgeRust;
    }

    unsafe extern "RustQt" {
        #[qsignal]
        fn user_message_added(self: Pin<&mut JarvisBridge>, content: QString);

        #[qsignal]
        fn jarvis_stream_chunk(self: Pin<&mut JarvisBridge>, content: QString, done: bool);

        #[qsignal]
        fn wake_word_detected(self: Pin<&mut JarvisBridge>);
    }

    unsafe extern "RustQt" {
        #[qinvokable]
        fn send_message(self: Pin<&mut JarvisBridge>, content: QString);

        #[qinvokable]
        fn poll_ipc(self: Pin<&mut JarvisBridge>);

        #[qinvokable]
        fn toggle_listening(self: Pin<&mut JarvisBridge>);
    }
}

pub struct JarvisBridgeRust {
    jarvis_state:    QString,
    connected:       bool,
    is_listening:    bool,
    ipc:             IpcClient,
    response_buffer: String,
}

impl Default for JarvisBridgeRust {
    fn default() -> Self {
        Self {
            jarvis_state:    QString::from("offline"),
            connected:       false,
            is_listening:    false,
            ipc:             IpcClient::new(),
            response_buffer: String::new(),
        }
    }
}

impl ffi::JarvisBridge {
    fn send_message(self: Pin<&mut Self>, content: QString) {
        let text = content.to_string();
        if text.trim().is_empty() { return; }
        self.as_mut().user_message_added(content);
        self.rust().ipc.send_message(text);
    }

    fn poll_ipc(self: Pin<&mut Self>) {
        while let Some(event) = self.rust().ipc.try_recv() {
            match event {
                IpcEvent::Connected => {
                    self.as_mut().set_connected(true);
                    self.as_mut().set_jarvis_state(QString::from("idle"));
                }
                IpcEvent::Disconnected => {
                    self.as_mut().set_connected(false);
                    self.as_mut().set_is_listening(false);
                    self.as_mut().set_jarvis_state(QString::from("offline"));
                }
                IpcEvent::State(state) => {
                    let listening = state == "listening";
                    self.as_mut().set_is_listening(listening);
                    self.as_mut().set_jarvis_state(QString::from(&*state));
                }
                IpcEvent::ResponseChunk { content, done } => {
                    unsafe { self.as_mut().rust_mut() }.response_buffer.push_str(&content);
                    if done {
                        let full = unsafe { &self.rust_unchecked().response_buffer }.clone();
                        unsafe { self.as_mut().rust_mut() }.response_buffer.clear();
                        self.as_mut().jarvis_stream_chunk(QString::from(&*full), true);
                        self.as_mut().set_jarvis_state(QString::from("idle"));
                    } else {
                        self.as_mut().jarvis_stream_chunk(QString::from(&*content), false);
                    }
                }
                IpcEvent::WakeWordDetected => {
                    self.as_mut().set_jarvis_state(QString::from("listening"));
                    self.as_mut().set_is_listening(true);
                    self.as_mut().wake_word_detected();
                }
                IpcEvent::Error(_) => {}
            }
        }
    }

    fn toggle_listening(self: Pin<&mut Self>) {
        if self.is_listening() {
            self.rust().ipc.stop_listening();
            self.as_mut().set_is_listening(false);
            self.as_mut().set_jarvis_state(QString::from("idle"));
        } else {
            self.rust().ipc.start_listening();
            self.as_mut().set_is_listening(true);
            self.as_mut().set_jarvis_state(QString::from("listening"));
        }
    }
}
```

---

### `rust/resources.qrc`

```xml
<!DOCTYPE RCC>
<RCC version="1.0">
    <qresource prefix="/qt/qml/JarvisUI">
        <file>qml/Main.qml</file>
        <file>qml/ChatView.qml</file>
        <file>qml/MessageBubble.qml</file>
        <file>qml/InputBar.qml</file>
        <file>qml/StatusIndicator.qml</file>
    </qresource>
</RCC>
```

---

### `rust/qml/Main.qml`

```qml
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import JarvisUI 1.0

ApplicationWindow {
    id: root
    width: 500
    height: 760
    minimumWidth: 400
    minimumHeight: 540
    visible: true
    title: "JARVIS"
    color: JarvisTheme.bg

    QtObject {
        id: JarvisTheme
        readonly property color bg:           "#0a0e1a"
        readonly property color surface:      "#0f1520"
        readonly property color card:         "#141c2e"
        readonly property color border:       "#1a2540"
        readonly property color primary:      "#00c8ff"
        readonly property color primaryDim:   "#007aaa"
        readonly property color primaryGlow:  "#1a5070"
        readonly property color accent:       "#00e5ff"
        readonly property color textPrimary:  "#d8eeff"
        readonly property color textSecondary:"#5a7a9a"
        readonly property color userBubble:   "#0d3050"
        readonly property color jarvisBubble: "#111927"
        readonly property color listening:    "#00ff88"
        readonly property color processing:   "#ffaa00"
        readonly property color speaking:     "#aa44ff"
        readonly property color offline:      "#ff4455"
        readonly property color idle:         "#00c8ff"
        readonly property int   radius:       16
        readonly property int   msgRadius:    14
        readonly property string fontMono:    "Hack, JetBrains Mono, monospace"
    }

    JarvisBridge {
        id: bridge
        onUserMessageAdded: function(content) { chatView.addUserMessage(content) }
        onJarvisStreamChunk: function(content, done) { chatView.appendJarvisChunk(content, done) }
        onWakeWordDetected: { /* optional: flash border or play sound */ }
    }

    Timer {
        interval: 50
        running: true
        repeat: true
        onTriggered: bridge.pollIpc()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header
        Rectangle {
            Layout.fillWidth: true
            height: 64
            color: JarvisTheme.surface

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: JarvisTheme.border
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 20; anchors.rightMargin: 20
                spacing: 12

                Column {
                    spacing: 2
                    Text {
                        text: "JARVIS"
                        font.pixelSize: 20; font.letterSpacing: 4; font.weight: Font.Bold
                        color: JarvisTheme.primary
                    }
                    Text {
                        text: "AI Operating System"
                        font.pixelSize: 10; font.letterSpacing: 1
                        color: JarvisTheme.textSecondary
                    }
                }

                Item { Layout.fillWidth: true }

                StatusIndicator {
                    state_: bridge.jarvisState
                    connected: bridge.connected
                }
            }
        }

        ChatView {
            id: chatView
            Layout.fillWidth: true
            Layout.fillHeight: true
            theme: JarvisTheme
        }

        Rectangle {
            Layout.fillWidth: true; height: 1
            color: JarvisTheme.border
        }

        InputBar {
            id: inputBar
            Layout.fillWidth: true
            theme: JarvisTheme
            isListening: bridge.isListening
            isConnected: bridge.connected
            onSendMessage: function(text) { bridge.sendMessage(text) }
            onToggleListening: { bridge.toggleListening() }
        }
    }
}
```

---

### `rust/qml/ChatView.qml`

```qml
import QtQuick 2.15
import QtQuick.Controls 2.15

Item {
    id: root
    required property var theme

    function addUserMessage(content) {
        messageModel.append({
            content: content, isUser: true, isStreaming: false,
            timestamp: Qt.formatTime(new Date(), "hh:mm")
        })
        scrollToBottom()
    }

    function appendJarvisChunk(content, done) {
        var lastIdx = messageModel.count - 1
        if (lastIdx >= 0 && !messageModel.get(lastIdx).isUser
                         && messageModel.get(lastIdx).isStreaming) {
            messageModel.setProperty(lastIdx, "content",
                messageModel.get(lastIdx).content + content)
            if (done) messageModel.setProperty(lastIdx, "isStreaming", false)
        } else {
            messageModel.append({
                content: content, isUser: false, isStreaming: !done,
                timestamp: Qt.formatTime(new Date(), "hh:mm")
            })
        }
        scrollToBottom()
    }

    function scrollToBottom() {
        Qt.callLater(function() { listView.positionViewAtEnd() })
    }

    Rectangle { anchors.fill: parent; color: theme.bg }

    ListModel { id: messageModel }

    ListView {
        id: listView
        anchors.fill: parent
        model: messageModel
        spacing: 4
        clip: true
        topMargin: 16; bottomMargin: 16

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            contentItem: Rectangle {
                implicitWidth: 4; radius: 2
                color: theme.primaryDim; opacity: 0.5
            }
            background: Rectangle { color: "transparent" }
        }

        delegate: MessageBubble {
            width: listView.width
            theme: root.theme
            content: model.content
            isUser: model.isUser
            isStreaming: model.isStreaming
            timestamp: model.timestamp
        }

        footer: Item {
            width: listView.width
            height: messageModel.count === 0
                ? listView.height - listView.topMargin - listView.bottomMargin : 0
            visible: messageModel.count === 0

            Column {
                anchors.centerIn: parent
                spacing: 16

                Rectangle {
                    width: 72; height: 72; radius: 36
                    color: "transparent"
                    border.color: theme.primary; border.width: 1.5
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        width: 56; height: 56; radius: 28
                        color: "transparent"
                        border.color: theme.primaryDim; border.width: 1
                        anchors.centerIn: parent
                        Text {
                            anchors.centerIn: parent
                            text: "J"; font.pixelSize: 28; font.weight: Font.Bold
                            color: theme.primary
                        }
                    }

                    SequentialAnimation on opacity {
                        running: true; loops: Animation.Infinite
                        NumberAnimation { to: 0.4; duration: 1500; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1500; easing.type: Easing.InOutSine }
                    }
                }

                Text {
                    text: "Hello. I'm JARVIS."
                    font.pixelSize: 18; font.letterSpacing: 2
                    color: theme.textPrimary
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: "How can I assist you today?"
                    font.pixelSize: 13; color: theme.textSecondary
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }
}
```

---

### `rust/qml/MessageBubble.qml`

```qml
import QtQuick 2.15

Item {
    id: root
    required property var    theme
    required property string content
    required property bool   isUser
    required property bool   isStreaming
    required property string timestamp

    height: row.implicitHeight + 12
    width: parent ? parent.width : 400

    Component.onCompleted: { opacity = 0; slideIn.start() }
    SequentialAnimation {
        id: slideIn
        PropertyAnimation { target: root; property: "opacity"; from: 0; to: 1; duration: 200 }
    }
    opacity: 0

    Row {
        id: row
        anchors {
            left:        isUser ? undefined : parent.left
            right:       isUser ? parent.right : undefined
            leftMargin:  isUser ? 0 : 16
            rightMargin: isUser ? 16 : 0
            verticalCenter: parent.verticalCenter
        }

        Rectangle {
            visible: !isUser
            width: 28; height: 28; radius: 14
            color: "transparent"
            border.color: root.theme.primaryDim; border.width: 1
            Text {
                anchors.centerIn: parent
                text: "J"; font.pixelSize: 13; font.weight: Font.Bold
                color: root.theme.primary
            }
        }

        Item { width: isUser ? 0 : 8; height: 1 }

        Column {
            spacing: 4
            width: Math.min(implicitWidth, root.width * 0.78)

            Rectangle {
                width: textContent.implicitWidth + 24
                height: textContent.implicitHeight + 18
                radius: root.theme.msgRadius
                color: isUser ? root.theme.userBubble : root.theme.jarvisBubble
                border.color: isUser
                    ? Qt.rgba(0, 0.78, 1, 0.25) : Qt.rgba(0, 0.78, 1, 0.10)
                border.width: 1

                Rectangle {
                    visible: !isUser
                    anchors { top: parent.top; left: parent.left; right: parent.right }
                    height: 1; color: Qt.rgba(0, 0.78, 1, 0.15)
                }

                Text {
                    id: textContent
                    anchors {
                        left: parent.left; right: parent.right; top: parent.top
                        leftMargin: 12; rightMargin: 12; topMargin: 9
                    }
                    text: root.content + (root.isStreaming ? " ▌" : "")
                    wrapMode: Text.Wrap
                    font.pixelSize: 14
                    font.family: root.isUser ? "sans-serif" : root.theme.fontMono
                    color: root.theme.textPrimary
                    lineHeight: 1.4
                    textFormat: Text.PlainText
                }
            }

            Text {
                anchors.right: isUser ? parent.right : undefined
                text: root.timestamp
                font.pixelSize: 10; color: root.theme.textSecondary
            }
        }
    }
}
```

---

### `rust/qml/InputBar.qml`

```qml
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: root
    height: 72
    color: theme.surface

    required property var  theme
    required property bool isListening
    required property bool isConnected

    signal sendMessage(string text)
    signal toggleListening()

    function _submit() {
        var text = field.text.trim()
        if (text.length === 0) return
        sendMessage(text)
        field.text = ""
    }

    RowLayout {
        anchors { fill: parent; leftMargin: 16; rightMargin: 16; topMargin: 12; bottomMargin: 12 }
        spacing: 10

        Rectangle {
            Layout.fillWidth: true; height: 44; radius: 22
            color: theme.card
            border.color: field.activeFocus
                ? Qt.rgba(0, 0.78, 1, 0.55) : Qt.rgba(0, 0.78, 1, 0.15)
            border.width: field.activeFocus ? 1.5 : 1
            Behavior on border.color { ColorAnimation { duration: 150 } }

            TextInput {
                id: field
                anchors {
                    left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                    leftMargin: 18; rightMargin: 18
                }
                font.pixelSize: 14; color: theme.textPrimary
                selectionColor: Qt.rgba(0, 0.78, 1, 0.30)
                selectedTextColor: theme.textPrimary
                clip: true; enabled: isConnected
                Keys.onReturnPressed: root._submit()
                Keys.onEnterPressed:  root._submit()

                Text {
                    visible: !field.text && !field.activeFocus
                    text: isConnected ? "Message JARVIS…" : "Connecting to daemon…"
                    font: field.font; color: theme.textSecondary
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        Rectangle {
            width: 44; height: 44; radius: 22
            color: isListening
                ? Qt.rgba(0, 1, 0.53, 0.15) : Qt.rgba(0, 0.78, 1, 0.10)
            border.color: isListening ? theme.listening : theme.primaryDim
            border.width: 1
            Behavior on color { ColorAnimation { duration: 150 } }

            Rectangle {
                anchors.centerIn: parent
                width: parent.width + 10; height: parent.height + 10
                radius: (parent.width + 10) / 2
                color: "transparent"
                border.color: theme.listening; border.width: 1.5
                visible: isListening
                SequentialAnimation on opacity {
                    running: isListening; loops: Animation.Infinite
                    NumberAnimation { to: 0.6; duration: 700 }
                    NumberAnimation { to: 0.0; duration: 700 }
                }
                SequentialAnimation on scale {
                    running: isListening; loops: Animation.Infinite
                    NumberAnimation { to: 1.15; duration: 700 }
                    NumberAnimation { to: 1.0;  duration: 700 }
                }
            }

            Text {
                anchors.centerIn: parent
                text: isListening ? "⏹" : "🎤"
                font.pixelSize: 18
                color: isListening ? theme.listening : theme.primaryDim
            }

            MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleListening()
            }
        }

        Rectangle {
            width: 44; height: 44; radius: 22
            color: sendArea.pressed
                ? Qt.rgba(0, 0.78, 1, 0.35)
                : sendArea.containsMouse
                    ? Qt.rgba(0, 0.78, 1, 0.20) : Qt.rgba(0, 0.78, 1, 0.12)
            border.color: theme.primary; border.width: 1
            enabled: isConnected && field.text.trim().length > 0
            opacity: enabled ? 1.0 : 0.35
            Behavior on color   { ColorAnimation { duration: 100 } }
            Behavior on opacity { NumberAnimation { duration: 150 } }

            Text { anchors.centerIn: parent; text: "▶"; font.pixelSize: 16; color: theme.primary }

            MouseArea {
                id: sendArea; anchors.fill: parent
                cursorShape: Qt.PointingHandCursor; hoverEnabled: true
                onClicked: root._submit()
            }
        }
    }
}
```

---

### `rust/qml/StatusIndicator.qml`

```qml
import QtQuick 2.15

Row {
    id: root
    spacing: 8

    property string state_:    "offline"
    property bool   connected: false

    readonly property string label: {
        switch (state_) {
            case "idle":       return "Idle"
            case "listening":  return "Listening"
            case "processing": return "Processing"
            case "speaking":   return "Speaking"
            default:           return "Offline"
        }
    }

    readonly property color dotColor: {
        switch (state_) {
            case "idle":       return "#00c8ff"
            case "listening":  return "#00ff88"
            case "processing": return "#ffaa00"
            case "speaking":   return "#aa44ff"
            default:           return "#ff4455"
        }
    }

    readonly property bool pulsing: state_ === "listening"
                                 || state_ === "processing"
                                 || state_ === "speaking"

    Rectangle {
        width: 10; height: 10; radius: 5
        anchors.verticalCenter: parent.verticalCenter
        color: root.dotColor
        Behavior on color { ColorAnimation { duration: 300 } }

        Rectangle {
            anchors.centerIn: parent
            width: 18; height: 18; radius: 9
            color: "transparent"
            border.color: root.dotColor; border.width: 1
            SequentialAnimation on opacity {
                running: root.pulsing; loops: Animation.Infinite
                NumberAnimation { to: 0.7; duration: 600 }
                NumberAnimation { to: 0.1; duration: 600 }
            }
        }

        SequentialAnimation on scale {
            running: root.pulsing; loops: Animation.Infinite
            NumberAnimation { to: 1.2; duration: 500 }
            NumberAnimation { to: 1.0; duration: 500 }
        }
    }

    Text {
        text: root.label
        font.pixelSize: 12; font.letterSpacing: 1
        color: root.dotColor
        anchors.verticalCenter: parent.verticalCenter
        Behavior on color { ColorAnimation { duration: 300 } }
    }
}
```

---

## Integration Checklist

### Python daemon
1. Copy `ipc_server.py` → `Project-JARVIS/jarvis/ipc_server.py`
2. Apply the 6 TODO hooks from `main_integration.py` into your `Jarvis` class
3. The key hook is `handle_text_input` — wire it to your existing LLM call path

### Rust app
1. Place all `rust/` contents into the `jarvis-ui/` repo
2. Install build deps on host: `sudo dnf install qt6-qtbase-devel qt6-qtdeclarative-devel cmake ninja-build`
3. `cd rust && cargo build --release`
4. Add to `04-bake-jarvis.sh` to bake into ISO

### 04-bake-jarvis.sh addition
```bash
# Install Qt6 build deps
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    qt6-base qt6-declarative cmake ninja rust

# Build jarvis-ui
sudo cp -r "${PROJECT_ROOT}/jarvis-ui/rust" "${SQUASHFS_ROOTFS}/tmp/jarvis-ui"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    cd /tmp/jarvis-ui && cargo build --release
    cp target/release/jarvis-ui /usr/bin/jarvis-ui
    rm -rf /tmp/jarvis-ui
"
```

---

## Next Milestone: Plasma Widget

The widget will reuse `ipc.rs` and `ipc_server.py` unchanged.
It connects to the same `/tmp/jarvis.sock` and listens for
`wake_word_detected` and `state` events to show/hide the overlay.
Architecture: Plasma Applet (QML) + CXX-Qt backend toggled via `plasmoid.expanded`.
