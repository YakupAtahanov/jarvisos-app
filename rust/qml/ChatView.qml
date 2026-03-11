import QtQuick 2.15
import QtQuick.Controls 2.15

Item {
    id: root
    required property var theme

    function addUserMessage(content) {
        messageModel.append({
            content: content, isUser: true, isStreaming: false,
            timestamp: Qt.formatTime(new Date(), "hh:mm")
        })
        scrollToBottom()
    }

    function appendJarvisChunk(content, done) {
        var lastIdx = messageModel.count - 1
        if (lastIdx >= 0 && !messageModel.get(lastIdx).isUser
                         && messageModel.get(lastIdx).isStreaming) {
            messageModel.setProperty(lastIdx, "content",
                messageModel.get(lastIdx).content + content)
            if (done) messageModel.setProperty(lastIdx, "isStreaming", false)
        } else {
            messageModel.append({
                content: content, isUser: false, isStreaming: !done,
                timestamp: Qt.formatTime(new Date(), "hh:mm")
            })
        }
        scrollToBottom()
    }

    function scrollToBottom() {
        Qt.callLater(function() { listView.positionViewAtEnd() })
    }

    Rectangle { anchors.fill: parent; color: theme.bg }

    ListModel { id: messageModel }

    ListView {
        id: listView
        anchors.fill: parent
        model: messageModel
        spacing: 4
        clip: true
        topMargin: 16; bottomMargin: 16

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
            contentItem: Rectangle {
                implicitWidth: 4; radius: 2
                color: theme.primaryDim; opacity: 0.5
            }
            background: Rectangle { color: "transparent" }
        }

        delegate: MessageBubble {
            width: listView.width
            theme: root.theme
            content: model.content
            isUser: model.isUser
            isStreaming: model.isStreaming
            timestamp: model.timestamp
        }

        footer: Item {
            width: listView.width
            height: messageModel.count === 0
                ? listView.height - listView.topMargin - listView.bottomMargin : 0
            visible: messageModel.count === 0

            Column {
                anchors.centerIn: parent
                spacing: 16

                Rectangle {
                    width: 72; height: 72; radius: 36
                    color: "transparent"
                    border.color: theme.primary; border.width: 1.5
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        width: 56; height: 56; radius: 28
                        color: "transparent"
                        border.color: theme.primaryDim; border.width: 1
                        anchors.centerIn: parent
                        Text {
                            anchors.centerIn: parent
                            text: "J"; font.pixelSize: 28; font.weight: Font.Bold
                            color: theme.primary
                        }
                    }

                    SequentialAnimation on opacity {
                        running: true; loops: Animation.Infinite
                        NumberAnimation { to: 0.4; duration: 1500; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1500; easing.type: Easing.InOutSine }
                    }
                }

                Text {
                    text: "Hello. I'm JARVIS."
                    font.pixelSize: 18; font.letterSpacing: 2
                    color: theme.textPrimary
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: "How can I assist you today?"
                    font.pixelSize: 13; color: theme.textSecondary
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }
}
