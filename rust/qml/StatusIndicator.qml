import QtQuick 2.15

Row {
    id: root
    spacing: 8

    property string state_:    "offline"
    property bool   connected: false

    readonly property string label: {
        switch (state_) {
            case "idle":       return "Idle"
            case "listening":  return "Listening"
            case "processing": return "Processing"
            case "speaking":   return "Speaking"
            default:           return "Offline"
        }
    }

    readonly property color dotColor: {
        switch (state_) {
            case "idle":       return "#00c8ff"
            case "listening":  return "#00ff88"
            case "processing": return "#ffaa00"
            case "speaking":   return "#aa44ff"
            default:           return "#ff4455"
        }
    }

    readonly property bool pulsing: state_ === "listening"
                                 || state_ === "processing"
                                 || state_ === "speaking"

    Rectangle {
        width: 10; height: 10; radius: 5
        anchors.verticalCenter: parent.verticalCenter
        color: root.dotColor
        Behavior on color { ColorAnimation { duration: 300 } }

        Rectangle {
            anchors.centerIn: parent
            width: 18; height: 18; radius: 9
            color: "transparent"
            border.color: root.dotColor; border.width: 1
            SequentialAnimation on opacity {
                running: root.pulsing; loops: Animation.Infinite
                NumberAnimation { to: 0.7; duration: 600 }
                NumberAnimation { to: 0.1; duration: 600 }
            }
        }

        SequentialAnimation on scale {
            running: root.pulsing; loops: Animation.Infinite
            NumberAnimation { to: 1.2; duration: 500 }
            NumberAnimation { to: 1.0; duration: 500 }
        }
    }

    Text {
        text: root.label
        font.pixelSize: 12; font.letterSpacing: 1
        color: root.dotColor
        anchors.verticalCenter: parent.verticalCenter
        Behavior on color { ColorAnimation { duration: 300 } }
    }
}
