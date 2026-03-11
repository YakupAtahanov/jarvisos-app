import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: root
    height: 72
    color: theme.surface

    required property var  theme
    required property bool isListening
    required property bool isConnected

    signal sendMessage(string text)
    signal toggleListening()

    function _submit() {
        var text = field.text.trim()
        if (text.length === 0) return
        sendMessage(text)
        field.text = ""
    }

    RowLayout {
        anchors { fill: parent; leftMargin: 16; rightMargin: 16; topMargin: 12; bottomMargin: 12 }
        spacing: 10

        Rectangle {
            Layout.fillWidth: true; height: 44; radius: 22
            color: theme.card
            border.color: field.activeFocus
                ? Qt.rgba(0, 0.78, 1, 0.55) : Qt.rgba(0, 0.78, 1, 0.15)
            border.width: field.activeFocus ? 1.5 : 1
            Behavior on border.color { ColorAnimation { duration: 150 } }

            TextInput {
                id: field
                anchors {
                    left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                    leftMargin: 18; rightMargin: 18
                }
                font.pixelSize: 14; color: theme.textPrimary
                selectionColor: Qt.rgba(0, 0.78, 1, 0.30)
                selectedTextColor: theme.textPrimary
                clip: true; enabled: isConnected
                Keys.onReturnPressed: root._submit()
                Keys.onEnterPressed:  root._submit()

                Text {
                    visible: !field.text && !field.activeFocus
                    text: isConnected ? "Message JARVIS\u2026" : "Connecting to daemon\u2026"
                    font: field.font; color: theme.textSecondary
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        Rectangle {
            width: 44; height: 44; radius: 22
            color: isListening
                ? Qt.rgba(0, 1, 0.53, 0.15) : Qt.rgba(0, 0.78, 1, 0.10)
            border.color: isListening ? theme.listening : theme.primaryDim
            border.width: 1
            Behavior on color { ColorAnimation { duration: 150 } }

            Rectangle {
                anchors.centerIn: parent
                width: parent.width + 10; height: parent.height + 10
                radius: (parent.width + 10) / 2
                color: "transparent"
                border.color: theme.listening; border.width: 1.5
                visible: isListening
                SequentialAnimation on opacity {
                    running: isListening; loops: Animation.Infinite
                    NumberAnimation { to: 0.6; duration: 700 }
                    NumberAnimation { to: 0.0; duration: 700 }
                }
                SequentialAnimation on scale {
                    running: isListening; loops: Animation.Infinite
                    NumberAnimation { to: 1.15; duration: 700 }
                    NumberAnimation { to: 1.0;  duration: 700 }
                }
            }

            Text {
                anchors.centerIn: parent
                text: isListening ? "\u23F9" : "\uD83C\uDFA4"
                font.pixelSize: 18
                color: isListening ? theme.listening : theme.primaryDim
            }

            MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleListening()
            }
        }

        Rectangle {
            width: 44; height: 44; radius: 22
            color: sendArea.pressed
                ? Qt.rgba(0, 0.78, 1, 0.35)
                : sendArea.containsMouse
                    ? Qt.rgba(0, 0.78, 1, 0.20) : Qt.rgba(0, 0.78, 1, 0.12)
            border.color: theme.primary; border.width: 1
            enabled: isConnected && field.text.trim().length > 0
            opacity: enabled ? 1.0 : 0.35
            Behavior on color   { ColorAnimation { duration: 100 } }
            Behavior on opacity { NumberAnimation { duration: 150 } }

            Text { anchors.centerIn: parent; text: "\u25B6"; font.pixelSize: 16; color: theme.primary }

            MouseArea {
                id: sendArea; anchors.fill: parent
                cursorShape: Qt.PointingHandCursor; hoverEnabled: true
                onClicked: root._submit()
            }
        }
    }
}
