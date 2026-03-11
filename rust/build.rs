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
