# jarvis-widget — Claude Code Handoff (Milestone 2)

## Overview

A **compact, center-top floating widget** for the JARVIS daemon. Hidden by default —
appears only when triggered by a **global keybinding** (interactive mode) or the
**wake word** (ghost/HUD mode). Same Rust + CXX-Qt + Qt6/QML stack as milestone 1.

**Stack:** Rust · CXX-Qt 0.7 · Qt6/QML · Python asyncio
**Socket:** `/tmp/jarvis.sock` (JSON-L, bidirectional — shared with jarvis-ui)
**Theme:** JARVIS cyan (`#00c8ff` / `#00e5ff`) on dark navy

---

## Two Activation Modes

### Mode 1: Wake Word → Ghost / HUD Mode

| Aspect          | Behavior                                                    |
|-----------------|-------------------------------------------------------------|
| **Trigger**     | Daemon sends `{"type": "wake_word_detected"}` over IPC      |
| **Interaction** | Non-interactive — click-through (`WA_TransparentForMouseEvents`) |
| **On hover**    | Opacity drops further (70% → 20%)                           |
| **Content**     | Streaming JARVIS response text (+ audio plays via daemon)   |
| **Dismiss**     | Auto-dismiss when `{"type": "response", "done": true}`      |
| **Stop**        | Global keybind (e.g. `SUPER+X`) sends `--stop` to process   |

### Mode 2: Keybinding → Interactive Mode

| Aspect          | Behavior                                                    |
|-----------------|-------------------------------------------------------------|
| **Trigger**     | Compositor keybind runs `jarvis-widget --toggle`            |
| **Interaction** | Fully interactive — clickable, typeable, focused            |
| **Input**       | Text input bar, auto-focused on appear                      |
| **Content**     | JARVIS response + follow-up input                           |
| **Dismiss**     | `Escape` key or click outside the widget                    |
| **Stop**        | Same global keybind (`SUPER+X`) sends `--stop`              |

---

## Keybinding Integration

Global keybindings are handled by the **Hyprland compositor**, not the widget binary.
Users configure them through the JarvisOS **System Settings → Shortcuts** catalogue.

**Default shipped bindings** (in Hyprland config):

```ini
# JARVIS Widget
bind = SUPER, J, exec, jarvis-widget --toggle
bind = SUPER, X, exec, jarvis-widget --stop
```

The widget binary is keybinding-agnostic — it only responds to CLI flags.

---

## IPC Protocol Additions

New message added to the existing protocol:

```
Client → Daemon
  {"type": "stop_stream"}          ← stop current response + TTS playback
```

All other messages are unchanged from milestone 1.

---

## Architecture

```
Daemon (Python)                      Widget (Rust + Qt)
    │                                      │
    │── wake_word_detected ───────────────▶ show(ghost mode)
    │                                      │  - transparent, click-through
    │── response chunks ──────────────────▶  - display streaming text
    │── response done ────────────────────▶  - auto-dismiss
    │                                      │
    │                                Hyprland bind → --toggle:
    │                                      │  show(interactive mode)
    │◀── user message ────────────────────│  - focused, typeable
    │── response chunks ──────────────────▶  - display streaming text
    │                                      │  - Escape to dismiss
    │                                      │
    │                                Hyprland bind → --stop:
    │◀── stop_stream ─────────────────────│  - stop response + TTS
    │                                      │  - fade out + hide
```

---

## Single-Instance Mechanism

Only one widget process runs at a time. Uses a **control socket** at
`/tmp/jarvis-widget.sock` for instance coordination:

1. On launch, try to bind `/tmp/jarvis-widget.sock`
2. If bind succeeds → this is the primary instance; listen for commands
3. If bind fails → another instance exists; send the CLI command (`toggle`/`stop`)
   to the existing instance via the control socket, then exit

---

## Repo Structure

```
jarvis-widget/
├── Cargo.toml
├── build.rs
├── resources.qrc
├── src/
│   ├── main.rs              ← CLI args, single-instance, control socket
│   ├── ipc.rs               ← Daemon IPC client (adapted from jarvis-ui)
│   └── bridge.rs            ← CXX-Qt bridge for widget state
└── qml/
    ├── Widget.qml           ← Main frameless window, mode switching
    ├── ResponseView.qml     ← Streaming response display (shared by both modes)
    └── InputBar.qml         ← Text input (interactive mode only)
```

---

## Visual Design

**Position:** Center-top of screen, ~60px from top edge
**Size:** ~600px wide, height auto (content-driven, max ~300px)
**Appearance:** Frameless, rounded corners (12px), subtle drop shadow
**Fade-in:** ~120ms on appear
**Fade-out:** ~100ms on dismiss

### Ghost Mode
- Background: `#0a0e1a` at 70% opacity
- Text: `#d8eeff` (streaming with cursor `▌`)
- Border: 1px `#00c8ff` at 30% opacity
- Hover → entire widget drops to 20% opacity

### Interactive Mode
- Background: `#0a0e1a` at 95% opacity
- Input bar at bottom, cyan focus ring
- Same streaming text display
- Border: 1px `#00c8ff` at 60% opacity

---

## Widget.qml Window Flags

```qml
flags: Qt.FramelessWindowHint
     | Qt.WindowStaysOnTopHint
     | Qt.Tool                    // no taskbar entry
     | Qt.WA_ShowWithoutActivating // ghost mode: don't steal focus
```

---

## Python Daemon Changes

Add `stop_stream` handling to `ipc_server.py`:

```python
# In _process_message():
elif msg_type == "stop_stream":
    if self.on_stop_stream:
        await self.on_stop_stream()
```

The daemon's `on_stop_stream` callback should:
1. Cancel the current LLM streaming task
2. Stop TTS audio playback
3. Broadcast `{"type": "response", "content": "", "done": true}` to finalize

---

## Build & Run

```bash
cd jarvis-widget
cargo build --release

# Primary instance (stays running, hidden)
./target/release/jarvis-widget &

# Toggle interactive mode (from keybind)
jarvis-widget --toggle

# Stop stream + dismiss (from keybind)
jarvis-widget --stop
```

---

## Dependencies

Same as milestone 1 plus:
- No new crate dependencies needed
- Reuses `serde`, `serde_json`, `cxx-qt`, `cxx-qt-lib`, `chrono`
