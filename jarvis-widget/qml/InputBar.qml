import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Compact input bar for interactive mode.
// Emits messageSent(text) when the user submits.

Item {
    id: root
    height: 36

    signal messageSent(string text)

    function focusInput() {
        inputField.forceActiveFocus()
    }

    Rectangle {
        anchors.fill: parent
        radius: 18
        color: "#0f1520"
        border.color: inputField.activeFocus ? "#00c8ff" : "#1a2540"
        border.width: 1

        Behavior on border.color {
            ColorAnimation { duration: 200 }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 6
            spacing: 6

            TextInput {
                id: inputField
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter

                color: "#d8eeff"
                selectionColor: "#00c8ff"
                selectedTextColor: "#0a0e1a"
                font.pixelSize: 13
                font.family: "Hack, JetBrains Mono, monospace"
                clip: true

                property string placeholderText: "Ask JARVIS..."

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: inputField.placeholderText
                    color: "#5a7a9a"
                    font: inputField.font
                    visible: !inputField.text && !inputField.activeFocus
                }

                Keys.onReturnPressed: submit()
                Keys.onEnterPressed: submit()

                function submit() {
                    let msg = text.trim()
                    if (msg.length > 0) {
                        root.messageSent(msg)
                        text = ""
                    }
                }
            }

            // Send button
            Rectangle {
                width: 26
                height: 26
                radius: 13
                color: inputField.text.trim().length > 0
                    ? (sendArea.containsMouse ? "#00e5ff" : "#00c8ff")
                    : "#1a2540"
                Layout.alignment: Qt.AlignVCenter

                Behavior on color {
                    ColorAnimation { duration: 150 }
                }

                Text {
                    anchors.centerIn: parent
                    text: "→"
                    color: inputField.text.trim().length > 0 ? "#0a0e1a" : "#5a7a9a"
                    font.pixelSize: 14
                    font.bold: true
                }

                MouseArea {
                    id: sendArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: inputField.text.trim().length > 0
                        ? Qt.PointingHandCursor : Qt.ArrowCursor

                    onClicked: {
                        if (inputField.text.trim().length > 0) {
                            inputField.submit()
                        }
                    }
                }
            }
        }
    }
}
