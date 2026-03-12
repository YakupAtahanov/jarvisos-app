import QtQuick
import QtQuick.Controls

// Scrollable streaming response text display.
// Used by both ghost and interactive modes.

Item {
    id: root

    property string fullText: ""
    property bool streaming: false

    function appendChunk(content, done) {
        fullText += content
        streaming = !done
    }

    function clear() {
        fullText = ""
        streaming = false
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: parent.width
        contentHeight: responseText.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // Auto-scroll to bottom as text streams in
        onContentHeightChanged: {
            if (contentHeight > height) {
                contentY = contentHeight - height
            }
        }

        Text {
            id: responseText
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText

            text: root.fullText + (root.streaming ? "▌" : "")

            color: "#d8eeff"
            font.pixelSize: 13
            font.family: "Hack, JetBrains Mono, monospace"
            lineHeight: 1.4

            // Cursor blink animation
            Timer {
                running: root.streaming
                interval: 530
                repeat: true
                property bool cursorVisible: true
                onTriggered: {
                    cursorVisible = !cursorVisible
                    responseText.text = root.fullText + (cursorVisible ? "▌" : " ")
                }
                onRunningChanged: {
                    if (!running) {
                        responseText.text = root.fullText
                    }
                }
            }
        }
    }

    // Thin scrollbar
    ScrollBar {
        id: scrollBar
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 3
        policy: flick.contentHeight > flick.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff

        contentItem: Rectangle {
            implicitWidth: 3
            color: "#00c8ff"
            opacity: 0.3
            radius: 1.5
        }
    }

    // Empty state
    Text {
        anchors.centerIn: parent
        visible: root.fullText === "" && !root.streaming
        text: "..."
        color: "#5a7a9a"
        font.pixelSize: 13
        font.family: "Hack, JetBrains Mono, monospace"
        opacity: 0.5
    }
}
