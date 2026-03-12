import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import JarvisWidget 1.0

Window {
    id: root
    width: 600
    height: contentColumn.implicitHeight + 32
    maximumHeight: 320

    // Center-top positioning
    x: (Screen.width - width) / 2
    y: 60

    visible: false
    color: "transparent"

    flags: Qt.FramelessWindowHint
         | Qt.WindowStaysOnTopHint
         | Qt.Tool
         | Qt.WA_ShowWithoutActivating

    // -- Theme --
    readonly property color bgColor:      "#0a0e1a"
    readonly property color primaryCyan:   "#00c8ff"
    readonly property color textPrimary:   "#d8eeff"
    readonly property color textSecondary: "#5a7a9a"

    // -- State --
    property bool ghostMode: false
    property real baseOpacity: ghostMode ? 0.70 : 0.95
    property real hoverDim: 1.0  // drops on hover in ghost mode

    WidgetBridge {
        id: bridge

        onWakeWordDetected: {
            responseView.clear()
            root.ghostMode = true
            root.showWidget()
        }

        onShowInteractive: {
            responseView.clear()
            root.ghostMode = false
            root.showWidget()
            inputBar.focusInput()
        }

        onHideWidget: {
            root.hideWidget()
        }

        onJarvisStreamChunk: function(content, done) {
            responseView.appendChunk(content, done)
            if (done && root.ghostMode) {
                // Auto-dismiss after a short delay in ghost mode
                dismissTimer.restart()
            }
        }
    }

    // Poll IPC every 50ms
    Timer {
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            bridge.pollIpc()
            pollControlCommands()
        }
    }

    // Auto-dismiss timer for ghost mode (1.5s after response done)
    Timer {
        id: dismissTimer
        interval: 1500
        repeat: false
        onTriggered: {
            if (root.ghostMode) {
                root.hideWidget()
            }
        }
    }

    // -- Visual container --
    Rectangle {
        id: container
        anchors.fill: parent
        anchors.margins: 4
        radius: 12
        color: root.bgColor
        opacity: root.baseOpacity * root.hoverDim
        border.color: root.primaryCyan
        border.width: 1
        border.pixelAligned: true

        layer.enabled: true
        layer.effect: null

        Behavior on opacity {
            NumberAnimation { duration: 150 }
        }

        // Ghost mode: become more transparent on hover
        MouseArea {
            id: hoverArea
            anchors.fill: parent
            hoverEnabled: true
            propagateComposedEvents: true
            acceptedButtons: root.ghostMode ? Qt.NoButton : Qt.AllButtons

            onEntered: {
                if (root.ghostMode) {
                    root.hoverDim = 0.28  // ~20% total (0.70 * 0.28)
                }
            }
            onExited: {
                root.hoverDim = 1.0
            }

            // Pass through clicks in ghost mode
            onPressed: function(mouse) {
                if (!root.ghostMode) {
                    mouse.accepted = false
                }
            }
        }

        ColumnLayout {
            id: contentColumn
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            // Status indicator
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                    width: 8
                    height: 8
                    radius: 4
                    color: {
                        switch (bridge.jarvisState) {
                            case "listening":   return "#00ff88"
                            case "processing":  return "#ffaa00"
                            case "speaking":    return "#aa44ff"
                            case "offline":     return "#ff4455"
                            default:            return root.primaryCyan
                        }
                    }

                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        running: bridge.jarvisState === "listening"
                              || bridge.jarvisState === "processing"
                              || bridge.jarvisState === "speaking"
                        NumberAnimation { to: 0.3; duration: 600 }
                        NumberAnimation { to: 1.0; duration: 600 }
                        onRunningChanged: {
                            if (!running) parent.opacity = 1.0
                        }
                    }
                }

                Text {
                    text: {
                        switch (bridge.jarvisState) {
                            case "listening":   return "Listening..."
                            case "processing":  return "Processing..."
                            case "speaking":    return "Speaking..."
                            case "offline":     return "Offline"
                            default:            return "JARVIS"
                        }
                    }
                    color: root.textSecondary
                    font.pixelSize: 11
                    font.family: "Hack, JetBrains Mono, monospace"
                }

                Item { Layout.fillWidth: true }

                // Close / stop button (always clickable, even in ghost mode)
                Rectangle {
                    width: 20
                    height: 20
                    radius: 10
                    color: stopBtnArea.containsMouse ? "#ff4455" : "transparent"
                    border.color: root.textSecondary
                    border.width: 1
                    visible: root.visible

                    Text {
                        anchors.centerIn: parent
                        text: bridge.isStreaming ? "■" : "✕"
                        color: root.textPrimary
                        font.pixelSize: bridge.isStreaming ? 8 : 10
                    }

                    MouseArea {
                        id: stopBtnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        // This button is ALWAYS clickable, even in ghost mode
                        onClicked: {
                            if (bridge.isStreaming) {
                                bridge.stopStream()
                            }
                            root.hideWidget()
                        }
                    }
                }
            }

            // Response area
            ResponseView {
                id: responseView
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 30
                Layout.maximumHeight: 220
            }

            // Input bar (interactive mode only)
            InputBar {
                id: inputBar
                Layout.fillWidth: true
                visible: !root.ghostMode
                enabled: !root.ghostMode && bridge.connected

                onMessageSent: function(text) {
                    responseView.clear()
                    bridge.sendMessage(text)
                }
            }
        }
    }

    // -- Fade animations --
    NumberAnimation {
        id: fadeIn
        target: root
        property: "opacity"
        from: 0.0
        to: 1.0
        duration: 120
    }

    NumberAnimation {
        id: fadeOut
        target: root
        property: "opacity"
        from: 1.0
        to: 0.0
        duration: 100
        onFinished: {
            root.visible = false
            root.opacity = 1.0
        }
    }

    // -- Methods --
    function showWidget() {
        dismissTimer.stop()
        root.opacity = 0.0
        root.visible = true
        fadeIn.start()
    }

    function hideWidget() {
        dismissTimer.stop()
        if (root.visible) {
            fadeOut.start()
        }
        bridge.dismiss()
    }

    // Poll for control commands from --toggle / --stop invocations
    function pollControlCommands() {
        // Read command file written by the control socket thread
        var xhr = Qt.createQmlObject(
            'import QtQuick; Item { }', root, "dynamic"
        )
        // We'll use the bridge to poll instead — check a simple file
        // This is handled in bridge.pollIpc() via a timer
    }

    // Escape key dismisses in interactive mode
    Keys.onEscapePressed: {
        if (!ghostMode) {
            hideWidget()
        }
    }

    // Click-outside detection: when window loses focus in interactive mode
    onActiveFocusItemChanged: {
        if (!ghostMode && visible && !activeFocusItem) {
            // Small delay to avoid dismissing on internal focus changes
            Qt.callLater(function() {
                if (!root.activeFocusItem && !root.ghostMode) {
                    hideWidget()
                }
            })
        }
    }
}
