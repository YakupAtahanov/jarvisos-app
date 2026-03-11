import QtQuick 2.15

Item {
    id: root
    required property var    theme
    required property string content
    required property bool   isUser
    required property bool   isStreaming
    required property string timestamp

    height: row.implicitHeight + 12
    width: parent ? parent.width : 400

    Component.onCompleted: { opacity = 0; slideIn.start() }
    SequentialAnimation {
        id: slideIn
        PropertyAnimation { target: root; property: "opacity"; from: 0; to: 1; duration: 200 }
    }
    opacity: 0

    Row {
        id: row
        anchors {
            left:        isUser ? undefined : parent.left
            right:       isUser ? parent.right : undefined
            leftMargin:  isUser ? 0 : 16
            rightMargin: isUser ? 16 : 0
            verticalCenter: parent.verticalCenter
        }

        Rectangle {
            visible: !isUser
            width: 28; height: 28; radius: 14
            color: "transparent"
            border.color: root.theme.primaryDim; border.width: 1
            Text {
                anchors.centerIn: parent
                text: "J"; font.pixelSize: 13; font.weight: Font.Bold
                color: root.theme.primary
            }
        }

        Item { width: isUser ? 0 : 8; height: 1 }

        Column {
            spacing: 4
            width: Math.min(implicitWidth, root.width * 0.78)

            Rectangle {
                width: textContent.implicitWidth + 24
                height: textContent.implicitHeight + 18
                radius: root.theme.msgRadius
                color: isUser ? root.theme.userBubble : root.theme.jarvisBubble
                border.color: isUser
                    ? Qt.rgba(0, 0.78, 1, 0.25) : Qt.rgba(0, 0.78, 1, 0.10)
                border.width: 1

                Rectangle {
                    visible: !isUser
                    anchors { top: parent.top; left: parent.left; right: parent.right }
                    height: 1; color: Qt.rgba(0, 0.78, 1, 0.15)
                }

                Text {
                    id: textContent
                    anchors {
                        left: parent.left; right: parent.right; top: parent.top
                        leftMargin: 12; rightMargin: 12; topMargin: 9
                    }
                    text: root.content + (root.isStreaming ? " \u258C" : "")
                    wrapMode: Text.Wrap
                    font.pixelSize: 14
                    font.family: root.isUser ? "sans-serif" : root.theme.fontMono
                    color: root.theme.textPrimary
                    lineHeight: 1.4
                    textFormat: Text.PlainText
                }
            }

            Text {
                anchors.right: isUser ? parent.right : undefined
                text: root.timestamp
                font.pixelSize: 10; color: root.theme.textSecondary
            }
        }
    }
}
