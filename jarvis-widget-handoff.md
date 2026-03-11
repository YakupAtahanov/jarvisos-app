# jarvis-ui — Milestone 2: Widget + Workspace Refactor

## Overview

This milestone does two things:
1. **Refactors the repo into a Cargo workspace** with a shared `jarvis-ipc` crate
2. **Adds `jarvis-widget`** — a Plasma applet with two modes: voice overlay and keyboard quick-access

The widget is a **quick UX surface only** — no settings, no MCP tools, no full history management. That lives in the app. The widget is: appear, pick session or start fresh, chat, disappear.

---

## Repo Structure After This Milestone

```
jarvis-ui/
├── Cargo.toml                     ← workspace root (NEW)
├── python/
│   ├── ipc_server.py              ← unchanged
│   ├── main_integration.py        ← unchanged
│   └── session_manager.py         ← NEW: session persistence
└── crates/
    ├── jarvis-ipc/                ← NEW: shared IPC crate
    │   ├── Cargo.toml
    │   └── src/
    │       └── lib.rs             ← ipc.rs promoted to library
    ├── jarvis-app/                ← MOVED from rust/
    │   ├── Cargo.toml             ← updated to use jarvis-ipc
    │   ├── build.rs
    │   ├── resources.qrc
    │   ├── src/
    │   │   ├── main.rs
    │   │   └── bridge.rs          ← ipc.rs removed, uses jarvis-ipc
    │   └── qml/                   ← unchanged
    └── jarvis-widget/             ← NEW: Plasma widget
        ├── Cargo.toml
        ├── build.rs
        ├── resources.qrc
        ├── src/
        │   ├── main.rs
        │   └── bridge.rs
        └── qml/
            ├── Widget.qml         ← root, mode switcher
            ├── VoiceOverlay.qml   ← Mode 1: wake word HUD
            ├── SessionList.qml    ← Mode 2 Screen 1: session picker
            └── QuickChat.qml      ← Mode 2 Screen 2: chat view
```

---

## Widget UX Spec

### Mode 1 — Voice Overlay (wake word triggered)
- Appears at top-right, semi-transparent (~85% opacity)
- Shows only the **current exchange**: user utterance + JARVIS response streaming in
- Animated state ring: green=listening, amber=processing, purple=speaking
- Auto-dismisses when state returns to `idle` after a response
- No interaction required — purely informational HUD

### Mode 2 — Quick Access (keybinding triggered)
- Same top-right position, slightly less transparent (~95% opacity)
- **Screen 1 — Session List:**
  - Recent sessions listed most-recent-first
  - Mouse wheel scrolls the list
  - Typing immediately filters sessions by title/content preview
  - Enter or click opens a session → switches to Screen 2
  - "New Chat" button at top always starts fresh
- **Screen 2 — Chat View:**
  - Full session history, scrollable with mouse wheel
  - Input bar at bottom, Enter to send
  - Backspace on empty input → back to Screen 1
  - Escape anywhere → dismiss widget entirely
- KGlobalAccel registers the keybinding (default: `Meta+Space`, user-configurable)

### Shared behavior
- Both modes use the same `JarvisTheme` color tokens as the app
- Widget never steals focus from the active window in voice mode
- In quick-access mode, widget takes focus for keyboard input

---

## New IPC Protocol Messages

Add these to the existing JSON-L protocol:

```
Client → Daemon:
  {"type": "get_sessions"}
  {"type": "switch_session", "session_id": "abc123"}
  {"type": "new_session"}

Daemon → Client:
  {"type": "sessions", "sessions": [
    {"id": "abc123", "title": "Turn off WiFi", "preview": "Sure, disabling...", "updated_at": 1234567890},
    ...
  ]}
  {"type": "session_switched", "session_id": "abc123"}
  {"type": "session_created",  "session_id": "xyz789"}
```

Session stubs are **lightweight** — id, title (first user message truncated to 40 chars), one-line preview, timestamp. No full history in the stub.

---

## File Contents

### `Cargo.toml` (workspace root)

```toml
[workspace]
resolver = "2"
members = [
    "crates/jarvis-ipc",
    "crates/jarvis-app",
    "crates/jarvis-widget",
]

[workspace.dependencies]
cxx-qt        = "0.7"
cxx-qt-lib    = { version = "0.7", features = ["full"] }
cxx-qt-build  = "0.7"
serde         = { version = "1", features = ["derive"] }
serde_json    = "1"
chrono        = { version = "0.4", features = ["clock"] }
```

---

### `crates/jarvis-ipc/Cargo.toml`

```toml
[package]
name = "jarvis-ipc"
version = "0.1.0"
edition = "2021"
description = "JARVIS OS – shared IPC client"

[dependencies]
serde      = { workspace = true }
serde_json = { workspace = true }
```

---

### `crates/jarvis-ipc/src/lib.rs`

```rust
//! JARVIS IPC Client — shared library
//!
//! Used by both jarvis-app and jarvis-widget.
//! Connects to /tmp/jarvis.sock, auto-reconnects on disconnect.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::thread;
use std::time::Duration;

pub const SOCKET_PATH: &str = "/tmp/jarvis.sock";
const RECONNECT_DELAY: Duration = Duration::from_secs(2);
const COMMAND_POLL: Duration = Duration::from_millis(50);

// ── Session stub (lightweight, for the widget session list) ──────────────────

#[derive(Debug, Clone, serde::Deserialize)]
pub struct SessionStub {
    pub id:         String,
    pub title:      String,   // first user message, truncated to 40 chars
    pub preview:    String,   // last JARVIS response, truncated to 80 chars
    pub updated_at: i64,      // unix timestamp
}

// ── Events delivered to the Qt thread ────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum IpcEvent {
    Connected,
    Disconnected,
    State(String),
    ResponseChunk { content: String, done: bool },
    WakeWordDetected,
    Sessions(Vec<SessionStub>),
    SessionSwitched(String),
    SessionCreated(String),
    Error(String),
}

// ── Commands sent from the Qt thread ─────────────────────────────────────────

#[derive(Debug)]
pub enum IpcCommand {
    SendMessage(String),
    StartListening,
    StopListening,
    GetSessions,
    SwitchSession(String),
    NewSession,
    Shutdown,
}

// ── Public client handle ──────────────────────────────────────────────────────

pub struct IpcClient {
    event_rx:   Receiver<IpcEvent>,
    command_tx: Sender<IpcCommand>,
}

impl IpcClient {
    pub fn new() -> Self {
        let (event_tx, event_rx)   = mpsc::channel::<IpcEvent>();
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

    pub fn get_sessions(&self) {
        let _ = self.command_tx.send(IpcCommand::GetSessions);
    }

    pub fn switch_session(&self, session_id: String) {
        let _ = self.command_tx.send(IpcCommand::SwitchSession(session_id));
    }

    pub fn new_session(&self) {
        let _ = self.command_tx.send(IpcCommand::NewSession);
    }
}

impl Default for IpcClient {
    fn default() -> Self { Self::new() }
}

// ── Background IPC thread ─────────────────────────────────────────────────────

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
    stream:     &UnixStream,
    event_tx:   &Sender<IpcEvent>,
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
        .expect("reader thread");

    let mut write_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => { eprintln!("jarvis-ipc: write clone: {e}"); return; }
    };

    loop {
        loop {
            match read_rx.try_recv() {
                Ok(Some(ev)) => { if event_tx.send(ev).is_err() { return; } }
                Ok(None)     => return,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return,
            }
        }

        match command_rx.recv_timeout(COMMAND_POLL) {
            Ok(cmd) => {
                let json = match &cmd {
                    IpcCommand::SendMessage(c)   => serde_json::json!({"type":"message","content":c}),
                    IpcCommand::StartListening   => serde_json::json!({"type":"start_listening"}),
                    IpcCommand::StopListening    => serde_json::json!({"type":"stop_listening"}),
                    IpcCommand::GetSessions      => serde_json::json!({"type":"get_sessions"}),
                    IpcCommand::SwitchSession(id)=> serde_json::json!({"type":"switch_session","session_id":id}),
                    IpcCommand::NewSession       => serde_json::json!({"type":"new_session"}),
                    IpcCommand::Shutdown         => return,
                };
                let msg = format!("{json}\n");
                if write_stream.write_all(msg.as_bytes()).is_err() { return; }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
    }
}

fn parse_daemon_message(line: &str) -> IpcEvent {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
        return IpcEvent::Error(format!("invalid JSON: {line}"));
    };

    match v.get("type").and_then(|t| t.as_str()) {
        Some("state")    => IpcEvent::State(
            v["state"].as_str().unwrap_or("idle").to_string()
        ),
        Some("response") => IpcEvent::ResponseChunk {
            content: v["content"].as_str().unwrap_or("").to_string(),
            done:    v["done"].as_bool().unwrap_or(true),
        },
        Some("wake_word_detected") => IpcEvent::WakeWordDetected,
        Some("sessions") => {
            let stubs = serde_json::from_value(v["sessions"].clone())
                .unwrap_or_default();
            IpcEvent::Sessions(stubs)
        }
        Some("session_switched") => IpcEvent::SessionSwitched(
            v["session_id"].as_str().unwrap_or("").to_string()
        ),
        Some("session_created") => IpcEvent::SessionCreated(
            v["session_id"].as_str().unwrap_or("").to_string()
        ),
        Some("error") => IpcEvent::Error(
            v["message"].as_str().unwrap_or("Unknown error").to_string()
        ),
        Some("ping") | Some("pong") => IpcEvent::State("idle".into()),
        other => IpcEvent::Error(format!("unknown type: {other:?}")),
    }
}
```

---

### `crates/jarvis-app/Cargo.toml` (updated)

```toml
[package]
name = "jarvis-app"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "jarvis-app"
path = "src/main.rs"

[dependencies]
jarvis-ipc = { path = "../jarvis-ipc" }
cxx-qt     = { workspace = true }
cxx-qt-lib = { workspace = true }
serde      = { workspace = true }
serde_json = { workspace = true }
chrono     = { workspace = true }

[build-dependencies]
cxx-qt-build = { workspace = true }

# NOTE: Delete crates/jarvis-app/src/ipc.rs — now provided by jarvis-ipc crate.
# In bridge.rs change:  use crate::ipc::...
#                   to:  use jarvis_ipc::...
```

---

### `crates/jarvis-widget/Cargo.toml`

```toml
[package]
name = "jarvis-widget"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "jarvis-widget"
path = "src/main.rs"

[dependencies]
jarvis-ipc = { path = "../jarvis-ipc" }
cxx-qt     = { workspace = true }
cxx-qt-lib = { workspace = true }
serde_json = { workspace = true }

[build-dependencies]
cxx-qt-build = { workspace = true }

# Runtime deps (Arch Linux):
#   sudo pacman -S plasma-framework5 kglobalaccel
```

---

### `crates/jarvis-widget/build.rs`

```rust
use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    CxxQtBuilder::new()
        .file("src/bridge.rs")
        .qml_module(QmlModule {
            uri: "JarvisWidget",
            version_major: 1,
            version_minor: 0,
            qml_files: &[
                "qml/Widget.qml",
                "qml/VoiceOverlay.qml",
                "qml/SessionList.qml",
                "qml/QuickChat.qml",
            ],
            ..Default::default()
        })
        .build();
}
```

---

### `crates/jarvis-widget/src/main.rs`

```rust
mod bridge;

use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QUrl, QString};

fn main() {
    let mut app = QGuiApplication::new();
    app.set_application_name(QString::from("JARVIS Widget"));
    app.set_organization_name(QString::from("JarvisOS"));

    let mut engine = QQmlApplicationEngine::default();
    engine.load(QUrl::from(QString::from(
        "qrc:/qt/qml/JarvisWidget/qml/Widget.qml"
    )));

    if engine.root_objects().is_empty() {
        eprintln!("jarvis-widget: failed to load Widget.qml");
        std::process::exit(1);
    }

    app.exec();
}
```

---

### `crates/jarvis-widget/src/bridge.rs`

```rust
//! CXX-Qt bridge for the JARVIS widget.
//!
//! Exposes WidgetBridge to QML. Handles both modes:
//!   Mode 1 – Voice overlay:    triggered by wake_word_detected event
//!   Mode 2 – Quick access:     triggered by KGlobalAccel keybinding
//!
//! QTimer polls pollIpc() every 50ms (same pattern as jarvis-app).

use std::pin::Pin;
use cxx_qt_lib::QString;
use jarvis_ipc::{IpcClient, IpcEvent, SessionStub};

#[cxx_qt::bridge]
pub mod ffi {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "RustQt" {
        #[qobject]
        #[qml_element]

        // ── Mode & visibility ─────────────────────────────────────────────────
        /// "hidden" | "voice" | "quick"
        #[qproperty(QString, mode)]
        /// Which screen is active in quick mode: "sessions" | "chat"
        #[qproperty(QString, screen)]

        // ── Daemon state ──────────────────────────────────────────────────────
        #[qproperty(QString, jarvis_state)]
        #[qproperty(bool, connected)]

        // ── Session list (Screen 1) ───────────────────────────────────────────
        /// JSON array of session stubs — parsed by QML into a ListModel
        #[qproperty(QString, sessions_json)]
        #[qproperty(QString, active_session_id)]

        type WidgetBridge = super::WidgetBridgeRust;
    }

    unsafe extern "RustQt" {
        // Emitted so QML can append/update the chat view
        #[qsignal]
        fn user_message_added(self: Pin<&mut WidgetBridge>, content: QString);

        #[qsignal]
        fn jarvis_stream_chunk(self: Pin<&mut WidgetBridge>, content: QString, done: bool);

        // Emitted when the widget should show in voice mode
        #[qsignal]
        fn wake_word_activated(self: Pin<&mut WidgetBridge>);

        // Emitted when the keybinding fires
        #[qsignal]
        fn quick_access_activated(self: Pin<&mut WidgetBridge>);
    }

    unsafe extern "RustQt" {
        /// Called by QTimer every 50ms
        #[qinvokable]
        fn poll_ipc(self: Pin<&mut WidgetBridge>);

        /// Send a message in the current session
        #[qinvokable]
        fn send_message(self: Pin<&mut WidgetBridge>, content: QString);

        /// Request session list from daemon
        #[qinvokable]
        fn request_sessions(self: Pin<&mut WidgetBridge>);

        /// Switch to a session by id
        #[qinvokable]
        fn switch_session(self: Pin<&mut WidgetBridge>, session_id: QString);

        /// Create a new session
        #[qinvokable]
        fn new_session(self: Pin<&mut WidgetBridge>);

        /// Show the widget in quick-access mode (called by keybinding handler)
        #[qinvokable]
        fn activate_quick(self: Pin<&mut WidgetBridge>);

        /// Dismiss the widget entirely
        #[qinvokable]
        fn dismiss(self: Pin<&mut WidgetBridge>);
    }
}

pub struct WidgetBridgeRust {
    mode:              QString,
    screen:            QString,
    jarvis_state:      QString,
    connected:         bool,
    sessions_json:     QString,
    active_session_id: QString,
    ipc:               IpcClient,
    response_buffer:   String,
}

impl Default for WidgetBridgeRust {
    fn default() -> Self {
        Self {
            mode:              QString::from("hidden"),
            screen:            QString::from("sessions"),
            jarvis_state:      QString::from("offline"),
            connected:         false,
            sessions_json:     QString::from("[]"),
            active_session_id: QString::from(""),
            ipc:               IpcClient::new(),
            response_buffer:   String::new(),
        }
    }
}

impl ffi::WidgetBridge {
    fn poll_ipc(self: Pin<&mut Self>) {
        while let Some(event) = self.rust().ipc.try_recv() {
            match event {
                IpcEvent::Connected => {
                    self.as_mut().set_connected(true);
                    self.as_mut().set_jarvis_state(QString::from("idle"));
                    // Fetch sessions on connect
                    self.rust().ipc.get_sessions();
                }

                IpcEvent::Disconnected => {
                    self.as_mut().set_connected(false);
                    self.as_mut().set_jarvis_state(QString::from("offline"));
                    self.as_mut().set_mode(QString::from("hidden"));
                }

                IpcEvent::State(state) => {
                    self.as_mut().set_jarvis_state(QString::from(&*state));
                    // Auto-dismiss voice overlay when returning to idle
                    if state == "idle" && self.mode().to_string() == "voice" {
                        // Small delay handled in QML with a Timer
                        // We just update state; QML watches jarvisState
                    }
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
                    self.as_mut().set_mode(QString::from("voice"));
                    self.as_mut().wake_word_activated();
                }

                IpcEvent::Sessions(stubs) => {
                    let json = serde_json::to_string(&stubs).unwrap_or_default();
                    self.as_mut().set_sessions_json(QString::from(&*json));
                }

                IpcEvent::SessionSwitched(id) => {
                    self.as_mut().set_active_session_id(QString::from(&*id));
                    self.as_mut().set_screen(QString::from("chat"));
                }

                IpcEvent::SessionCreated(id) => {
                    self.as_mut().set_active_session_id(QString::from(&*id));
                    self.as_mut().set_screen(QString::from("chat"));
                    self.rust().ipc.get_sessions(); // refresh list
                }

                IpcEvent::Error(_) => {}
            }
        }
    }

    fn send_message(self: Pin<&mut Self>, content: QString) {
        let text = content.to_string();
        if text.trim().is_empty() { return; }
        self.as_mut().user_message_added(content);
        self.rust().ipc.send_message(text);
    }

    fn request_sessions(self: Pin<&mut Self>) {
        self.rust().ipc.get_sessions();
    }

    fn switch_session(self: Pin<&mut Self>, session_id: QString) {
        self.rust().ipc.switch_session(session_id.to_string());
    }

    fn new_session(self: Pin<&mut Self>) {
        self.rust().ipc.new_session();
    }

    fn activate_quick(self: Pin<&mut Self>) {
        self.as_mut().set_mode(QString::from("quick"));
        self.as_mut().set_screen(QString::from("sessions"));
        self.as_mut().quick_access_activated();
        self.rust().ipc.get_sessions();
    }

    fn dismiss(self: Pin<&mut Self>) {
        self.as_mut().set_mode(QString::from("hidden"));
        self.as_mut().set_screen(QString::from("sessions"));
    }
}
```

---

### `crates/jarvis-widget/resources.qrc`

```xml
<!DOCTYPE RCC>
<RCC version="1.0">
    <qresource prefix="/qt/qml/JarvisWidget">
        <file>qml/Widget.qml</file>
        <file>qml/VoiceOverlay.qml</file>
        <file>qml/SessionList.qml</file>
        <file>qml/QuickChat.qml</file>
    </qresource>
</RCC>
```

---

### `crates/jarvis-widget/qml/Widget.qml`

```qml
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Window 2.15
import JarvisWidget 1.0

// Frameless, always-on-top overlay window
Window {
    id: root

    // ── Position: top-right, with margin ─────────────────────────────────────
    x: Screen.width - width - 24
    y: 24

    // Size changes per mode
    width:  bridge.mode === "hidden" ? 0 : bridge.mode === "voice" ? 320 : 380
    height: bridge.mode === "hidden" ? 0
          : bridge.mode === "voice"  ? 120
          : bridge.screen === "sessions" ? 480 : 520

    visible:      bridge.mode !== "hidden"
    flags:        Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
    color:        "transparent"
    opacity:      bridge.mode === "voice" ? 0.88 : 0.96

    Behavior on width  { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 150 } }

    // ── Shared theme tokens (identical to jarvis-app) ─────────────────────────
    QtObject {
        id: T
        readonly property color bg:           "#0a0e1a"
        readonly property color surface:      "#0f1520"
        readonly property color card:         "#141c2e"
        readonly property color border:       "#1a2540"
        readonly property color primary:      "#00c8ff"
        readonly property color primaryDim:   "#007aaa"
        readonly property color textPrimary:  "#d8eeff"
        readonly property color textSecondary:"#5a7a9a"
        readonly property color userBubble:   "#0d3050"
        readonly property color jarvisBubble: "#111927"
        readonly property color listening:    "#00ff88"
        readonly property color processing:   "#ffaa00"
        readonly property color speaking:     "#aa44ff"
        readonly property color offline:      "#ff4455"
        readonly property int   radius:       14
    }

    // ── Bridge ────────────────────────────────────────────────────────────────
    WidgetBridge {
        id: bridge

        onUserMessageAdded: function(content) {
            quickChat.addUserMessage(content)
        }
        onJarvisStreamChunk: function(content, done) {
            // Route to whichever view is active
            if (mode === "voice")  voiceOverlay.appendChunk(content, done)
            if (mode === "quick")  quickChat.appendChunk(content, done)
        }
        onWakeWordActivated: {
            voiceOverlay.reset()
        }
        onQuickAccessActivated: {
            sessionList.focusFilter()
        }
    }

    Timer {
        interval: 50; running: true; repeat: true
        onTriggered: bridge.pollIpc()
    }

    // ── Auto-dismiss voice overlay 1.5s after returning to idle ──────────────
    Timer {
        id: autoDismiss
        interval: 1500; repeat: false
        onTriggered: { if (bridge.mode === "voice") bridge.dismiss() }
    }

    Connections {
        target: bridge
        function onJarvisStateChanged() {
            if (bridge.jarvisState === "idle" && bridge.mode === "voice") {
                autoDismiss.restart()
            }
        }
    }

    // ── Escape to dismiss in quick mode ──────────────────────────────────────
    Keys.onEscapePressed: bridge.dismiss()

    // ── Mode router ───────────────────────────────────────────────────────────
    VoiceOverlay {
        id: voiceOverlay
        anchors.fill: parent
        theme: T
        visible: bridge.mode === "voice"
        jarvisState: bridge.jarvisState
    }

    SessionList {
        id: sessionList
        anchors.fill: parent
        theme: T
        visible: bridge.mode === "quick" && bridge.screen === "sessions"
        sessionsJson: bridge.sessionsJson

        onSessionSelected: function(sessionId) { bridge.switchSession(sessionId) }
        onNewChat:         { bridge.newSession() }
    }

    QuickChat {
        id: quickChat
        anchors.fill: parent
        theme: T
        visible: bridge.mode === "quick" && bridge.screen === "chat"
        jarvisState: bridge.jarvisState
        isConnected: bridge.connected

        onSendMessage:  function(text) { bridge.sendMessage(text) }
        onBackToList:   {
            bridge.screen = "sessions"   // direct property set; no invokable needed
            sessionList.focusFilter()
        }
    }
}
```

---

### `crates/jarvis-widget/qml/VoiceOverlay.qml`

```qml
import QtQuick 2.15
import QtQuick.Layouts 1.15

// Mode 1: minimal transparent HUD shown during voice interaction
Rectangle {
    id: root

    required property var    theme
    required property string jarvisState

    property string _userText:   ""
    property string _jarvisText: ""

    function reset() { _userText = ""; _jarvisText = "" }

    function appendChunk(content, done) {
        _jarvisText += content
    }

    // Called by Widget.qml bridge signal
    function setUserText(text) { _userText = text }

    radius: theme.radius
    color:  Qt.rgba(0.04, 0.07, 0.12, 0.90)
    border.color: stateColor()
    border.width: 1.5

    function stateColor() {
        switch (jarvisState) {
            case "listening":  return theme.listening
            case "processing": return theme.processing
            case "speaking":   return theme.speaking
            default:           return theme.primaryDim
        }
    }

    Behavior on border.color { ColorAnimation { duration: 300 } }

    RowLayout {
        anchors { fill: parent; margins: 16 }
        spacing: 14

        // ── Animated state ring ───────────────────────────────────────────────
        Rectangle {
            width: 48; height: 48; radius: 24
            color: "transparent"
            border.color: root.stateColor()
            border.width: 2

            Rectangle {
                anchors.centerIn: parent
                width: 36; height: 36; radius: 18
                color: Qt.rgba(0, 0, 0, 0)
                border.color: root.stateColor()
                border.width: 1
                opacity: 0.4
            }

            Text {
                anchors.centerIn: parent
                text: "J"; font.pixelSize: 20; font.weight: Font.Bold
                color: root.stateColor()
            }

            // Pulse when active
            SequentialAnimation on scale {
                running: jarvisState !== "idle" && jarvisState !== "offline"
                loops: Animation.Infinite
                NumberAnimation { to: 1.08; duration: 600; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.00; duration: 600; easing.type: Easing.InOutSine }
            }
        }

        // ── Current exchange text ─────────────────────────────────────────────
        Column {
            Layout.fillWidth: true
            spacing: 6

            Text {
                visible: root._userText.length > 0
                width: parent.width
                text: root._userText
                font.pixelSize: 12; color: theme.textSecondary
                wrapMode: Text.Wrap
                maximumLineCount: 1
                elide: Text.ElideRight
            }

            Text {
                visible: root._jarvisText.length > 0
                width: parent.width
                text: root._jarvisText
                font.pixelSize: 13; color: theme.textPrimary
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            // State label when no text yet
            Text {
                visible: root._userText.length === 0
                text: {
                    switch (jarvisState) {
                        case "listening":  return "Listening…"
                        case "processing": return "Thinking…"
                        case "speaking":   return "Speaking…"
                        default:           return ""
                    }
                }
                font.pixelSize: 13; font.letterSpacing: 1
                color: root.stateColor()
            }
        }
    }
}
```

---

### `crates/jarvis-widget/qml/SessionList.qml`

```qml
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

// Mode 2 Screen 1: scrollable session picker
Rectangle {
    id: root

    required property var    theme
    required property string sessionsJson

    signal sessionSelected(string sessionId)
    signal newChat()

    function focusFilter() { filterField.forceActiveFocus() }

    // Parse sessions JSON into a JS array
    property var sessions: {
        try { return JSON.parse(sessionsJson) } catch(e) { return [] }
    }

    // Filtered list based on filterField text
    property var filtered: {
        var q = filterField.text.toLowerCase().trim()
        if (q === "") return sessions
        return sessions.filter(function(s) {
            return s.title.toLowerCase().includes(q) ||
                   s.preview.toLowerCase().includes(q)
        })
    }

    radius: theme.radius
    color:  Qt.rgba(0.04, 0.07, 0.12, 0.96)
    border.color: theme.border; border.width: 1

    ColumnLayout {
        anchors { fill: parent; margins: 12 }
        spacing: 8

        // ── Header ────────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true

            Text {
                text: "JARVIS"
                font.pixelSize: 13; font.letterSpacing: 3; font.weight: Font.Bold
                color: theme.primary
            }
            Item { Layout.fillWidth: true }

            // New chat button
            Rectangle {
                width: 28; height: 28; radius: 14
                color: newChatArea.containsMouse
                    ? Qt.rgba(0, 0.78, 1, 0.20) : Qt.rgba(0, 0.78, 1, 0.10)
                border.color: theme.primaryDim; border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "+"; font.pixelSize: 18; color: theme.primary
                }
                MouseArea {
                    id: newChatArea; anchors.fill: parent
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: root.newChat()
                }
            }
        }

        // ── Filter input ──────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true; height: 34; radius: 17
            color: theme.card
            border.color: filterField.activeFocus
                ? Qt.rgba(0, 0.78, 1, 0.5) : Qt.rgba(0, 0.78, 1, 0.15)
            border.width: 1
            Behavior on border.color { ColorAnimation { duration: 150 } }

            TextInput {
                id: filterField
                anchors {
                    left: parent.left; right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: 14; rightMargin: 14
                }
                font.pixelSize: 13; color: theme.textPrimary
                clip: true

                Keys.onReturnPressed: {
                    if (root.filtered.length > 0)
                        root.sessionSelected(root.filtered[0].id)
                    else
                        root.newChat()
                }

                Text {
                    visible: !filterField.text
                    text: "Search or start typing…"
                    font: filterField.font; color: theme.textSecondary
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // ── Session list ──────────────────────────────────────────────────────
        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 4
            model: root.filtered

            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                contentItem: Rectangle {
                    implicitWidth: 3; radius: 1.5
                    color: theme.primaryDim; opacity: 0.4
                }
                background: Rectangle { color: "transparent" }
            }

            delegate: Rectangle {
                width: listView.width; height: 58; radius: 10
                color: itemArea.containsMouse
                    ? Qt.rgba(0, 0.78, 1, 0.10) : Qt.rgba(0, 0.78, 1, 0.04)
                border.color: Qt.rgba(0, 0.78, 1, 0.08); border.width: 1

                Column {
                    anchors {
                        left: parent.left; right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 12; rightMargin: 12
                    }
                    spacing: 3

                    Text {
                        width: parent.width
                        text: modelData.title
                        font.pixelSize: 13; font.weight: Font.Medium
                        color: theme.textPrimary
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: modelData.preview
                        font.pixelSize: 11
                        color: theme.textSecondary
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    id: itemArea; anchors.fill: parent
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: root.sessionSelected(modelData.id)
                }
            }

            // Empty state
            Text {
                visible: root.filtered.length === 0
                anchors.centerIn: parent
                text: filterField.text.length > 0 ? "No sessions found" : "No sessions yet"
                font.pixelSize: 12; color: theme.textSecondary
            }
        }
    }
}
```

---

### `crates/jarvis-widget/qml/QuickChat.qml`

```qml
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

// Mode 2 Screen 2: minimal chat view for the active session
Rectangle {
    id: root

    required property var    theme
    required property string jarvisState
    required property bool   isConnected

    signal sendMessage(string text)
    signal backToList()

    property var _messages: []

    function addUserMessage(content) {
        _messages.push({ content: content, isUser: true, streaming: false })
        messageModel.append({ content: content, isUser: true, streaming: false })
        scrollToBottom()
    }

    function appendChunk(content, done) {
        var last = messageModel.count - 1
        if (last >= 0 && !messageModel.get(last).isUser
                      && messageModel.get(last).streaming) {
            messageModel.setProperty(last, "content",
                messageModel.get(last).content + content)
            if (done) messageModel.setProperty(last, "streaming", false)
        } else {
            messageModel.append({ content: content, isUser: false, streaming: !done })
        }
        scrollToBottom()
    }

    function scrollToBottom() {
        Qt.callLater(function() { chatList.positionViewAtEnd() })
    }

    radius: theme.radius
    color:  Qt.rgba(0.04, 0.07, 0.12, 0.96)
    border.color: theme.border; border.width: 1

    ColumnLayout {
        anchors { fill: parent; margins: 0 }
        spacing: 0

        // ── Minimal header ────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true; height: 42
            color: Qt.rgba(0.06, 0.09, 0.16, 1)
            radius: theme.radius

            // Only round top corners
            Rectangle {
                anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                height: theme.radius; color: parent.color
            }

            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }

                // Back button
                Rectangle {
                    width: 26; height: 26; radius: 13
                    color: backArea.containsMouse
                        ? Qt.rgba(0, 0.78, 1, 0.15) : "transparent"
                    border.color: theme.primaryDim; border.width: 1

                    Text {
                        anchors.centerIn: parent
                        text: "‹"; font.pixelSize: 16; color: theme.primary
                    }
                    MouseArea {
                        id: backArea; anchors.fill: parent
                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.backToList()
                    }
                }

                Item { Layout.fillWidth: true }

                // State dot
                Rectangle {
                    width: 8; height: 8; radius: 4
                    color: {
                        switch (jarvisState) {
                            case "listening":  return theme.listening
                            case "processing": return theme.processing
                            case "speaking":   return theme.speaking
                            case "idle":       return theme.primary
                            default:           return theme.offline
                        }
                    }
                    Behavior on color { ColorAnimation { duration: 300 } }
                }
            }
        }

        // ── Messages ──────────────────────────────────────────────────────────
        ListModel { id: messageModel }

        ListView {
            id: chatList
            Layout.fillWidth: true; Layout.fillHeight: true
            model: messageModel
            spacing: 6; clip: true
            topMargin: 8; bottomMargin: 4

            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                contentItem: Rectangle {
                    implicitWidth: 3; radius: 1.5
                    color: theme.primaryDim; opacity: 0.4
                }
                background: Rectangle { color: "transparent" }
            }

            delegate: Item {
                width: chatList.width
                height: bubble.implicitHeight + 10

                Rectangle {
                    id: bubble
                    anchors {
                        left:        isUser ? undefined : parent.left
                        right:       isUser ? parent.right : undefined
                        leftMargin:  isUser ? 0 : 10
                        rightMargin: isUser ? 10 : 0
                        verticalCenter: parent.verticalCenter
                    }
                    width: Math.min(bubbleText.implicitWidth + 20, parent.width * 0.85)
                    implicitHeight: bubbleText.implicitHeight + 14
                    radius: 10
                    color: isUser ? theme.userBubble : theme.jarvisBubble
                    border.color: Qt.rgba(0, 0.78, 1, isUser ? 0.2 : 0.08)
                    border.width: 1

                    Text {
                        id: bubbleText
                        anchors {
                            left: parent.left; right: parent.right; top: parent.top
                            leftMargin: 10; rightMargin: 10; topMargin: 7
                        }
                        text: content + (streaming ? " ▌" : "")
                        font.pixelSize: 13
                        color: theme.textPrimary
                        wrapMode: Text.Wrap
                        lineHeight: 1.35
                        textFormat: Text.PlainText
                    }
                }
            }
        }

        // ── Input bar ─────────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true; height: 52
            color: Qt.rgba(0.06, 0.09, 0.16, 1)
            radius: theme.radius

            // Only round bottom corners
            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: theme.radius; color: parent.color
            }

            RowLayout {
                anchors { fill: parent; leftMargin: 10; rightMargin: 10; topMargin: 8; bottomMargin: 8 }
                spacing: 8

                Rectangle {
                    Layout.fillWidth: true; height: 34; radius: 17
                    color: theme.card
                    border.color: chatInput.activeFocus
                        ? Qt.rgba(0, 0.78, 1, 0.5) : Qt.rgba(0, 0.78, 1, 0.12)
                    border.width: 1
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    TextInput {
                        id: chatInput
                        anchors {
                            left: parent.left; right: parent.right
                            verticalCenter: parent.verticalCenter
                            leftMargin: 14; rightMargin: 14
                        }
                        font.pixelSize: 13; color: theme.textPrimary
                        clip: true; enabled: isConnected

                        Keys.onReturnPressed: {
                            var t = text.trim()
                            if (t.length === 0) { root.backToList(); return }
                            root.sendMessage(t)
                            text = ""
                        }
                        // Backspace on empty → back to session list
                        Keys.onPressed: function(e) {
                            if (e.key === Qt.Key_Backspace && text.length === 0) {
                                root.backToList()
                                e.accepted = true
                            }
                        }

                        Component.onCompleted: forceActiveFocus()

                        Text {
                            visible: !chatInput.text
                            text: "Message…"
                            font: chatInput.font; color: theme.textSecondary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                Rectangle {
                    width: 34; height: 34; radius: 17
                    color: sendA.pressed
                        ? Qt.rgba(0, 0.78, 1, 0.35) : Qt.rgba(0, 0.78, 1, 0.12)
                    border.color: theme.primary; border.width: 1
                    enabled: isConnected && chatInput.text.trim().length > 0
                    opacity: enabled ? 1.0 : 0.3
                    Behavior on opacity { NumberAnimation { duration: 150 } }

                    Text { anchors.centerIn: parent; text: "▶"; font.pixelSize: 14; color: theme.primary }
                    MouseArea {
                        id: sendA; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            var t = chatInput.text.trim()
                            if (t.length === 0) return
                            root.sendMessage(t); chatInput.text = ""
                        }
                    }
                }
            }
        }
    }
}
```

---

### `python/session_manager.py`

```python
"""
JARVIS Session Manager
======================
Persists chat sessions to ~/.local/share/jarvis/sessions/
Each session is a JSON file: {id}.json

Integrate into IPCServer by passing a SessionManager instance:
    session_mgr = SessionManager()
    ipc = IPCServer(
        on_text_message=self.handle_text_input,
        session_manager=session_mgr,
    )

Then handle the new IPC message types in ipc_server.py:
    elif msg_type == "get_sessions":
        sessions = self._session_manager.get_stubs()
        await self._write(writer, {"type": "sessions", "sessions": sessions})

    elif msg_type == "switch_session":
        session_id = msg.get("session_id")
        self._session_manager.switch(session_id)
        await self._write(writer, {"type": "session_switched", "session_id": session_id})

    elif msg_type == "new_session":
        session_id = self._session_manager.new()
        await self._broadcast({"type": "session_created", "session_id": session_id})
"""

import json
import uuid
import time
import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger("jarvis.sessions")

SESSIONS_DIR = Path.home() / ".local" / "share" / "jarvis" / "sessions"


class SessionManager:
    def __init__(self):
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        self._active_id: Optional[str] = None
        # Start with or resume the most recent session
        stubs = self.get_stubs()
        if stubs:
            self._active_id = stubs[0]["id"]
        else:
            self._active_id = self.new()

    # ── Public API ─────────────────────────────────────────────────────────────

    @property
    def active_id(self) -> str:
        return self._active_id

    def get_stubs(self) -> list[dict]:
        """Return lightweight session stubs sorted newest-first."""
        stubs = []
        for path in SESSIONS_DIR.glob("*.json"):
            try:
                data = json.loads(path.read_text())
                messages = data.get("messages", [])
                if not messages:
                    continue
                first_user = next(
                    (m["content"] for m in messages if m["role"] == "user"), ""
                )
                last_jarvis = next(
                    (m["content"] for m in reversed(messages) if m["role"] == "assistant"),
                    ""
                )
                stubs.append({
                    "id":         data["id"],
                    "title":      first_user[:40] or "New chat",
                    "preview":    last_jarvis[:80],
                    "updated_at": data.get("updated_at", 0),
                })
            except Exception as e:
                logger.warning(f"Could not read session {path.name}: {e}")

        return sorted(stubs, key=lambda s: s["updated_at"], reverse=True)

    def new(self) -> str:
        """Create a new empty session and make it active."""
        session_id = str(uuid.uuid4())[:8]
        data = {
            "id":         session_id,
            "messages":   [],
            "created_at": int(time.time()),
            "updated_at": int(time.time()),
        }
        self._write(session_id, data)
        self._active_id = session_id
        logger.info(f"New session: {session_id}")
        return session_id

    def switch(self, session_id: str) -> bool:
        """Switch active session. Returns False if session not found."""
        path = SESSIONS_DIR / f"{session_id}.json"
        if not path.exists():
            return False
        self._active_id = session_id
        logger.info(f"Switched to session: {session_id}")
        return True

    def append_message(self, role: str, content: str) -> None:
        """Append a message to the active session."""
        data = self._read(self._active_id) or {
            "id": self._active_id, "messages": [],
            "created_at": int(time.time()), "updated_at": int(time.time()),
        }
        data["messages"].append({
            "role":       role,
            "content":    content,
            "timestamp":  int(time.time()),
        })
        data["updated_at"] = int(time.time())
        self._write(self._active_id, data)

    def get_history(self) -> list[dict]:
        """Return the full message history of the active session."""
        data = self._read(self._active_id)
        return data.get("messages", []) if data else []

    # ── Internal ──────────────────────────────────────────────────────────────

    def _read(self, session_id: str) -> Optional[dict]:
        path = SESSIONS_DIR / f"{session_id}.json"
        try:
            return json.loads(path.read_text())
        except Exception:
            return None

    def _write(self, session_id: str, data: dict) -> None:
        path = SESSIONS_DIR / f"{session_id}.json"
        path.write_text(json.dumps(data, indent=2))
```

---

## Migration Checklist

### 1. Restructure the repo

```bash
mkdir -p crates/jarvis-ipc/src
mkdir -p crates/jarvis-app/src crates/jarvis-app/qml
mkdir -p crates/jarvis-widget/src crates/jarvis-widget/qml

# Move existing app files
mv rust/src/main.rs    crates/jarvis-app/src/
mv rust/src/bridge.rs  crates/jarvis-app/src/
mv rust/build.rs       crates/jarvis-app/
mv rust/resources.qrc  crates/jarvis-app/
mv rust/qml/*          crates/jarvis-app/qml/

# Promote ipc.rs to shared library
mv rust/src/ipc.rs     crates/jarvis-ipc/src/lib.rs

# Create workspace Cargo.toml (contents above)
# Create crates/jarvis-ipc/Cargo.toml (contents above)
```

### 2. Update jarvis-app bridge.rs

Change the import at the top of `crates/jarvis-app/src/bridge.rs`:
```rust
// Remove:  use crate::ipc::{IpcClient, IpcEvent};
// Add:
use jarvis_ipc::{IpcClient, IpcEvent};
```

### 3. Add session support to ipc_server.py

Add `session_manager` parameter to `IPCServer.__init__` and handle the three new message types in `_process_message`:
```python
elif msg_type == "get_sessions":
    sessions = self._session_manager.get_stubs()
    await self._write(writer, {"type": "sessions", "sessions": sessions})

elif msg_type == "switch_session":
    sid = msg.get("session_id", "")
    ok = self._session_manager.switch(sid)
    if ok:
        await self._write(writer, {"type": "session_switched", "session_id": sid})

elif msg_type == "new_session":
    sid = self._session_manager.new()
    await self._broadcast({"type": "session_created", "session_id": sid})
```

### 4. Wire session persistence into handle_text_input

```python
async def handle_text_input(self, content: str) -> None:
    self.session_manager.append_message("user", content)
    # ... LLM call ...
    self.session_manager.append_message("assistant", response)
```

### 5. Register global keybinding

The widget binary needs to register `Meta+Space` via KGlobalAccel. Add this to `main.rs` after creating the engine:
```rust
// TODO in Code session: wire KGlobalAccel via a Qt C++ shim or
// use a QML Shortcut with Qt.ApplicationShortcut scope as a
// simpler first-pass alternative.
```

### 6. Build

```bash
# From repo root — builds all three crates
cargo build --release

# Binaries:
# target/release/jarvis-app
# target/release/jarvis-widget
```

### 7. Add to 04-bake-jarvis.sh

```bash
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    cd /tmp/jarvis-ui && cargo build --release
    cp target/release/jarvis-app    /usr/bin/jarvis-app
    cp target/release/jarvis-widget /usr/bin/jarvis-widget
    rm -rf /tmp/jarvis-ui
"
```

---

## What the Widget Does NOT Have

To keep it explicit — the widget intentionally omits:
- Settings or configuration UI
- MCP tool browser
- Full conversation management (delete, rename, export)
- Model selection
- Any system controls

All of that lives in `jarvis-app`. The widget is purely: appear → chat → disappear.
