//! CXX-Qt bridge -- exposes WidgetBridge as a QML element.
//!
//! QML usage:
//!   import JarvisWidget 1.0
//!   WidgetBridge {
//!       id: bridge
//!       onJarvisStreamChunk: (content, done) => { ... }
//!       onWakeWordDetected: { ... }
//!       onShowInteractive: { ... }
//!       onHideWidget: { ... }
//!   }
//!
//! A QTimer in Widget.qml calls bridge.pollIpc() every 50 ms.

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
        #[qproperty(bool, is_streaming)]
        #[qproperty(bool, ghost_mode)]
        #[qproperty(bool, visible_state)]
        type WidgetBridge = super::WidgetBridgeRust;
    }

    unsafe extern "RustQt" {
        #[qsignal]
        fn jarvis_stream_chunk(self: Pin<&mut WidgetBridge>, content: QString, done: bool);

        #[qsignal]
        fn wake_word_detected(self: Pin<&mut WidgetBridge>);

        #[qsignal]
        fn show_interactive(self: Pin<&mut WidgetBridge>);

        #[qsignal]
        fn hide_widget(self: Pin<&mut WidgetBridge>);
    }

    unsafe extern "RustQt" {
        #[qinvokable]
        fn send_message(self: Pin<&mut WidgetBridge>, content: QString);

        #[qinvokable]
        fn poll_ipc(self: Pin<&mut WidgetBridge>);

        #[qinvokable]
        fn stop_stream(self: Pin<&mut WidgetBridge>);

        #[qinvokable]
        fn request_toggle(self: Pin<&mut WidgetBridge>);

        #[qinvokable]
        fn request_stop(self: Pin<&mut WidgetBridge>);

        #[qinvokable]
        fn dismiss(self: Pin<&mut WidgetBridge>);
    }
}

pub struct WidgetBridgeRust {
    jarvis_state:    QString,
    connected:       bool,
    is_streaming:    bool,
    ghost_mode:      bool,
    visible_state:   bool,
    ipc:             IpcClient,
    response_buffer: String,
}

impl Default for WidgetBridgeRust {
    fn default() -> Self {
        Self {
            jarvis_state:    QString::from("offline"),
            connected:       false,
            is_streaming:    false,
            ghost_mode:      false,
            visible_state:   false,
            ipc:             IpcClient::new(),
            response_buffer: String::new(),
        }
    }
}

impl ffi::WidgetBridge {
    fn send_message(self: Pin<&mut Self>, content: QString) {
        let text = content.to_string();
        if text.trim().is_empty() { return; }
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
                    self.as_mut().set_jarvis_state(QString::from("offline"));
                    // Hide widget on disconnect
                    self.as_mut().set_visible_state(false);
                    self.as_mut().set_is_streaming(false);
                }
                IpcEvent::State(state) => {
                    self.as_mut().set_jarvis_state(QString::from(&*state));
                }
                IpcEvent::ResponseChunk { content, done } => {
                    self.as_mut().set_is_streaming(!done);
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
                    // Show widget in ghost mode
                    self.as_mut().set_ghost_mode(true);
                    self.as_mut().set_visible_state(true);
                    self.as_mut().set_jarvis_state(QString::from("listening"));
                    self.as_mut().wake_word_detected();
                }
                IpcEvent::Error(_) => {}
            }
        }
    }

    fn stop_stream(self: Pin<&mut Self>) {
        self.rust().ipc.stop_stream();
        unsafe { self.as_mut().rust_mut() }.response_buffer.clear();
        self.as_mut().set_is_streaming(false);
        self.as_mut().set_jarvis_state(QString::from("idle"));
    }

    /// Called when the compositor triggers --toggle
    fn request_toggle(self: Pin<&mut Self>) {
        if self.visible_state() && !self.ghost_mode() {
            // Already visible in interactive mode -> hide
            self.as_mut().dismiss();
        } else {
            // Show in interactive mode
            self.as_mut().set_ghost_mode(false);
            self.as_mut().set_visible_state(true);
            self.as_mut().show_interactive();
        }
    }

    /// Called when the compositor triggers --stop
    fn request_stop(self: Pin<&mut Self>) {
        if self.is_streaming() {
            self.as_mut().stop_stream();
        }
        self.as_mut().set_visible_state(false);
        self.as_mut().set_ghost_mode(false);
        self.as_mut().hide_widget();
    }

    fn dismiss(self: Pin<&mut Self>) {
        self.as_mut().set_visible_state(false);
        self.as_mut().set_ghost_mode(false);
        self.as_mut().set_is_streaming(false);
        self.as_mut().hide_widget();
    }
}
