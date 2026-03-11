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
