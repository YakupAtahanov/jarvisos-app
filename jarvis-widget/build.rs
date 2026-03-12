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
                "qml/ResponseView.qml",
                "qml/InputBar.qml",
            ],
            ..Default::default()
        })
        .build();
}
