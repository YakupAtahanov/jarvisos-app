mod bridge;
mod ipc;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;
use std::thread;

use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QUrl, QString};

const CONTROL_SOCKET: &str = "/tmp/jarvis-widget.sock";

/// Commands sent via the control socket from secondary instances.
#[derive(Debug, PartialEq)]
enum ControlCommand {
    Toggle,
    Stop,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    // Determine the command from CLI args
    let command = if args.iter().any(|a| a == "--toggle") {
        Some(ControlCommand::Toggle)
    } else if args.iter().any(|a| a == "--stop") {
        Some(ControlCommand::Stop)
    } else {
        None // Primary instance: run the widget
    };

    // Try to send command to existing instance
    if let Some(cmd) = &command {
        if send_to_existing(cmd) {
            return; // Existing instance handled it
        }
    }

    // If we have a command but no existing instance, and the command is --stop,
    // there's nothing to stop — just exit.
    if command == Some(ControlCommand::Stop) {
        return;
    }

    // Remove stale socket file
    let _ = std::fs::remove_file(CONTROL_SOCKET);

    // Start control socket listener
    let (ctrl_tx, ctrl_rx) = mpsc::channel::<ControlCommand>();
    start_control_listener(ctrl_tx);

    // Start Qt application
    let mut app = QGuiApplication::new();
    app.set_application_name(QString::from("JARVIS Widget"));
    app.set_organization_name(QString::from("JarvisOS"));
    app.set_application_version(QString::from(env!("CARGO_PKG_VERSION")));

    let mut engine = QQmlApplicationEngine::default();

    // Expose the control channel receiver to QML via a context property
    // We'll poll it from the bridge alongside IPC polling
    engine.load(QUrl::from(QString::from(
        "qrc:/qt/qml/JarvisWidget/qml/Widget.qml",
    )));

    if engine.root_objects().is_empty() {
        eprintln!("jarvis-widget: failed to load Widget.qml");
        let _ = std::fs::remove_file(CONTROL_SOCKET);
        std::process::exit(1);
    }

    // Poll control commands and forward to bridge
    // The bridge's pollIpc() handles daemon events; we also need to forward
    // control socket commands. We do this via a separate thread that writes
    // to a pipe, but simpler: we'll use the QML timer + bridge approach.
    // Store ctrl_rx in a thread-safe way for the bridge to poll.
    // For simplicity, we use a background thread that interacts via
    // the daemon IPC mechanism (sends special events).
    thread::Builder::new()
        .name("jarvis-widget-ctrl".into())
        .spawn(move || {
            // Forward control commands by connecting to our own daemon socket
            // and sending synthetic messages. Alternatively, write to a file
            // that the bridge polls. For robustness, we use a simple approach:
            // write commands to a known pipe.
            for cmd in ctrl_rx {
                // Write control command to a temporary file that the bridge polls
                let cmd_str = match cmd {
                    ControlCommand::Toggle => "toggle",
                    ControlCommand::Stop => "stop",
                };
                let _ = std::fs::write("/tmp/jarvis-widget-cmd", cmd_str);
            }
        })
        .ok();

    app.exec();

    // Cleanup
    let _ = std::fs::remove_file(CONTROL_SOCKET);
    let _ = std::fs::remove_file("/tmp/jarvis-widget-cmd");
}

fn send_to_existing(cmd: &ControlCommand) -> bool {
    if let Ok(mut stream) = UnixStream::connect(CONTROL_SOCKET) {
        let msg = match cmd {
            ControlCommand::Toggle => "toggle\n",
            ControlCommand::Stop => "stop\n",
        };
        let _ = stream.write_all(msg.as_bytes());
        true
    } else {
        false
    }
}

fn start_control_listener(ctrl_tx: mpsc::Sender<ControlCommand>) {
    let listener = UnixListener::bind(CONTROL_SOCKET)
        .expect("failed to bind control socket");

    // Make socket accessible
    let _ = std::fs::set_permissions(
        CONTROL_SOCKET,
        std::os::unix::fs::PermissionsExt::from_mode(0o666),
    );

    thread::Builder::new()
        .name("jarvis-widget-listener".into())
        .spawn(move || {
            for conn in listener.incoming() {
                if let Ok(stream) = conn {
                    let reader = BufReader::new(stream);
                    for line in reader.lines().take(1) {
                        if let Ok(line) = line {
                            let cmd = match line.trim() {
                                "toggle" => Some(ControlCommand::Toggle),
                                "stop" => Some(ControlCommand::Stop),
                                _ => None,
                            };
                            if let Some(c) = cmd {
                                if ctrl_tx.send(c).is_err() { return; }
                            }
                        }
                    }
                }
            }
        })
        .expect("failed to spawn control listener");
}
