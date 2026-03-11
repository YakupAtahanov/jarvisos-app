//! CXX-Qt bridge -- exposes JarvisBridge as a QML element.
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
