# jarvis-ui

ChatGPT-style desktop UI for the JARVIS daemon, built with **Rust + CXX-Qt 0.7 + Qt6/QML**.

Connects to the JARVIS Python daemon over a bidirectional Unix socket (`/tmp/jarvis.sock`) using newline-delimited JSON.

## Features

- Streaming message display with typing indicator
- Wake word detection status
- Mic toggle with pulse animation
- Auto-reconnect to daemon
- Dark navy + JARVIS cyan theme

## Project Structure

```
python/
  ipc_server.py          # Async Unix socket server (daemon side)
  main_integration.py    # How to wire ipc_server into main.py
rust/
  Cargo.toml
  build.rs
  resources.qrc
  src/
    main.rs              # App entry point
    ipc.rs               # IPC client with auto-reconnect
    bridge.rs            # CXX-Qt bridge (QML <-> Rust)
  qml/
    Main.qml             # Root window, header, layout
    ChatView.qml         # Message list with streaming support
    MessageBubble.qml    # User/JARVIS message bubbles
    InputBar.qml         # Text input + mic + send button
    StatusIndicator.qml  # Animated status dot
```

## Build

### Prerequisites (Arch Linux)

```bash
sudo pacman -S qt6-base qt6-declarative cmake ninja rust
```

### Prerequisites (Fedora)

```bash
sudo dnf install qt6-qtbase-devel qt6-qtdeclarative-devel cmake ninja-build
```

### Compile

```bash
cd rust
cargo build --release
```

The binary will be at `rust/target/release/jarvis-ui`.

## IPC Protocol

| Direction | Message |
|-----------|---------|
| Client -> Daemon | `{"type": "message", "content": "..."}` |
| Client -> Daemon | `{"type": "start_listening"}` / `{"type": "stop_listening"}` |
| Client -> Daemon | `{"type": "ping"}` |
| Daemon -> Client | `{"type": "state", "state": "idle\|listening\|processing\|speaking\|offline"}` |
| Daemon -> Client | `{"type": "response", "content": "...", "done": false}` (streaming chunk) |
| Daemon -> Client | `{"type": "response", "content": "", "done": true}` (stream finished) |
| Daemon -> Client | `{"type": "wake_word_detected"}` |
| Daemon -> Client | `{"type": "error", "message": "..."}` |

## Integration

See `python/main_integration.py` for the 6 TODO steps to wire the IPC server into your existing JARVIS daemon class.

## License

MIT
