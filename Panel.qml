import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "qml/state"
import "qml/components"

Panel {
    id: root

    moduleName: "ollie.android"
    ipcTarget: "ollie.android"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    property var helperCommand: ["omarchy-android-helper", "--acceptance-log"]
    property bool helperShutdownPending: false
    readonly property var barIdentity: hostWidget || root
    readonly property string sessionState: pairingState.sessionState
    readonly property color contentForeground: root.barForeground

    implicitWidth: 320
    implicitHeight: 480

    function activatePrimary() {
        if (pairingState.pairingStage !== "manual-code")
            return

        var code = manualCode.text
        manualCode.text = ""
        pairingState.submitManualCode(code)
    }

    function finishHelperShutdown() {
        if (!helperShutdownPending)
            return

        helperShutdownPending = false
        helperStopTimer.stop()
        helperProcess.running = false
        if (pairingState.sessionState !== "ready")
            pairingState.reset()
    }

    onOpenedChanged: {
        if (opened) {
            helperShutdownPending = false
            helperStopTimer.stop()
            helperProcess.running = true
            pairingState.automaticPairingEnabled = true
            if (pairingState.helperReady && pairingState.sessionState === "unpaired")
                pairingState.startQrPairing()
        } else {
            manualCode.text = ""
            pairingState.automaticPairingEnabled = false
            if (helperProcess.running) {
                helperShutdownPending = true
                if (pairingState.sessionState === "ready"
                        || pairingState.pairingStage === "connected"
                        || pairingState.pairingStage === "session-starting") {
                    pairingState.stopSession()
                } else {
                    pairingState.cancelPairing()
                }
                helperStopTimer.restart()
            }
        }
    }

    PairingState {
        id: pairingState
        onCommandRequested: function(command) {
            if (!helperProcess.running) {
                pairingState.protocolFailure()
                return
            }
            helperProcess.write(command + "\n")
        }
        onPairingCancellationConfirmed: {
            if (root.helperShutdownPending) {
                root.finishHelperShutdown()
            } else if (root.opened && pairingState.helperReady
                       && pairingState.sessionState === "unpaired") {
                pairingState.startQrPairing()
            }
        }
        onSessionStopConfirmed: {
            if (root.helperShutdownPending)
                root.finishHelperShutdown()
        }
    }

    Timer {
        id: helperStopTimer
        interval: 2000
        repeat: false
        onTriggered: root.finishHelperShutdown()
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.opened
                 && pairingState.pairingStage === "qr-waiting"
                 && pairingState.qrExpiresInSeconds > 0
        onTriggered: pairingState.tickQrExpiry()
    }

    Process {
        id: helperProcess
        command: root.helperCommand
        stdinEnabled: true
        running: false
        stdout: SplitParser {
            onRead: function(line) {
                pairingState.receiveLine(line)
            }
        }
        onRunningChanged: {
            if (!running && root.opened)
                pairingState.protocolFailure()
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(320))
        contentHeight: panel.fittedContentHeight(content.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: manualCode.activeFocus || phonePreview.inputFocused
            onActivateRequested: root.activatePrimary()
            onCloseRequested: root.close()
            onTextKey: function(text) {
                if (text === "r" || text === "R")
                    pairingState.startQrPairing()
            }

            Column {
                id: content
                width: parent.width
                spacing: Style.space(12)

                PanelHero {
                    width: parent.width
                    title: pairingState.statusTitle
                    meta: "Omarchy Android"
                    detail: pairingState.sessionState
                    foreground: root.contentForeground
                }

                Text {
                    width: parent.width
                    text: pairingState.statusDescription
                    color: Qt.darker(root.contentForeground, 1.25)
                    font.family: Style.fontFamily
                    font.pixelSize: Style.fontBaseSize
                    wrapMode: Text.Wrap
                }
                Rectangle {
                    visible: pairingState.sessionState === "ready"
                    width: parent.width
                    height: Math.min(width * 16 / 9, Style.space(340))
                    color: Qt.darker(root.contentForeground, 2.4)
                    radius: Style.cornerRadius
                    clip: true

                    PhonePreview {
                        id: phonePreview
                        anchors.fill: parent
                        captureRequested: parent.visible && root.opened
                        inputEnabled: pairingState.sessionState === "ready"
                        foreground: root.contentForeground
                        background: parent.color
                        onTapRequested: function(x, y, displayWidth, displayHeight) {
                            pairingState.sendPointerTap(x, y, displayWidth, displayHeight)
                        }
                        onSwipeRequested: function(startX, startY, endX, endY,
                                                   displayWidth, displayHeight, durationMs) {
                            pairingState.sendPointerSwipe(startX, startY, endX, endY,
                                                          displayWidth, displayHeight, durationMs)
                        }
                        onKeyRequested: function(key) {
                            pairingState.sendKeyInput(key)
                        }
                        onTextRequested: function(text) {
                            pairingState.sendTextInput(text)
                        }
                    }
                }


                Rectangle {
                    visible: pairingState.pairingStage === "qr-waiting"
                             && pairingState.qrArtifact !== ""
                    width: Math.min(parent.width, Style.space(240))
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "white"
                    radius: Style.cornerRadius

                    Image {
                        anchors.fill: parent
                        anchors.margins: Style.space(10)
                        source: pairingState.qrArtifact === ""
                                ? ""
                                : "file://" + pairingState.qrArtifact
                        cache: false
                        fillMode: Image.PreserveAspectFit
                        smooth: false
                    }
                }

                Text {
                    visible: pairingState.pairingStage === "qr-waiting"
                             && pairingState.qrArtifact !== ""
                    width: parent.width
                    text: pairingState.qrExpiresInSeconds === 1
                          ? "Expires in 1 second"
                          : "Expires in " + pairingState.qrExpiresInSeconds + " seconds"
                    color: Qt.darker(root.contentForeground, 1.4)
                    font.family: Style.fontFamily
                    font.pixelSize: Style.fontBaseSize
                    horizontalAlignment: Text.AlignHCenter
                }

                TextField {
                    id: manualCode
                    width: parent.width
                    visible: pairingState.pairingStage === "manual-code"
                    placeholderText: "Pairing code"
                    inputMethodHints: Qt.ImhDigitsOnly
                    onAccepted: root.activatePrimary()
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(8)
                    Button {
                        visible: pairingState.sessionState === "qr-waiting"
                                 && pairingState.pairingStage !== "manual-code"
                        text: "Pair by code"
                        onClicked: pairingState.useManualCode()
                    }

                    Button {
                        visible: pairingState.pairingStage === "manual-code"
                        text: "Pair"
                        onClicked: root.activatePrimary()
                    }

                    Button {
                        visible: pairingState.sessionState === "disconnected"
                        text: "Reconnect"
                        onClicked: pairingState.reconnectTrustedDevice()
                    }

                }
            }
        }
    }
}
