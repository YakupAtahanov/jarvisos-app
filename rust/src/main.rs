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
