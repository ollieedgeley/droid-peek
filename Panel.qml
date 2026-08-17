import QtQuick
import QtQuick.Window
import Quickshell.Io
import Quickshell.Hyprland
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
    property bool settingsOpen: false
    readonly property var barIdentity: hostWidget || root
    readonly property string sessionState: pairingState.sessionState
    readonly property color contentForeground: root.barForeground
    readonly property var phonePreview: phonePreviewLoader.item
    readonly property var outputMonitor: panel.screen
                                         ? Hyprland.monitorFor(panel.screen)
                                         : null
    readonly property real outputScale: outputMonitor && outputMonitor.scale > 0
                                        ? outputMonitor.scale
                                        : Screen.devicePixelRatio
    readonly property real logicalPixelsPerMm: outputScale > 0
                                                ? Screen.pixelDensity / outputScale
                                                : 0

    implicitWidth: 320
    implicitHeight: 480

    function sourceDimensions() {
        return Qt.size(phonePreview && phonePreview.displayWidth > 0
                       ? phonePreview.displayWidth : 9,
                       phonePreview && phonePreview.displayHeight > 0
                       ? phonePreview.displayHeight : 20)
    }

    function fallbackPreviewSize(percent) {
        var source = sourceDimensions()
        var width = Style.space(360) * percent / 100
        var height = Style.space(420) * percent / 100
        var fit = Math.min(width / source.width, height / source.height)
        return Qt.size(Math.max(1, Math.round(source.width * fit)),
                       Math.max(1, Math.round(source.height * fit)))
    }

    function rawPreviewSize(percent) {
        var source = sourceDimensions()
        var physical = pairingState.physicalPreviewSize(
                    root.logicalPixelsPerMm, source.width, source.height, percent)
        return physical.width > 0 && physical.height > 0
                ? physical : fallbackPreviewSize(percent)
    }

    function previewViewportSize(availableHeight) {
        var maximum = rawPreviewSize(150)
        var maxWidth = Screen.width > 0
                ? Math.max(Style.space(280), Screen.width - Style.space(80))
                : maximum.width
        var maxHeight = availableHeight > 0
                ? Math.max(Style.space(210), availableHeight - Style.space(120))
                : maximum.height
        var fit = Math.min(1, maxWidth / maximum.width, maxHeight / maximum.height)
        return Qt.size(Math.max(1, Math.round(maximum.width * fit)),
                       Math.max(1, Math.round(maximum.height * fit)))
    }

    function desiredPreviewSize(availableHeight) {
        var current = rawPreviewSize(pairingState.previewScale)
        var maximum = rawPreviewSize(150)
        var viewport = previewViewportSize(availableHeight)
        var fit = Math.min(viewport.width / maximum.width,
                           viewport.height / maximum.height)
        return Qt.size(Math.max(1, Math.round(current.width * fit)),
                       Math.max(1, Math.round(current.height * fit)))
    }

    function desiredPanelWidth() {
        if (pairingState.sessionState === "ready")
            return Math.max(Style.space(280),
                            previewViewportSize(panel.availableCardHeight).width)
        return Style.space(320)
    }

    function desiredPreviewHeight(availableHeight) {
        return previewViewportSize(availableHeight).height
    }

    function runQuickAction(action) {
        pairingState.sendKeyInput(action)
        if (phonePreview) {
            Qt.callLater(function() {
                if (root.phonePreview)
                    root.phonePreview.forceActiveFocus()
            })
        }
    }

    function updateRenderPreferences(scale, quality, actions) {
        pairingState.setRenderPreferences(scale, quality, actions)
    }

    function triggerSemanticAction(actionId) {
        return semanticActionRouter.trigger(actionId)
    }

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
        if (!opened)
            settingsOpen = false
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

    SemanticActionRouter {
        id: semanticActionRouter
        sessionReady: pairingState.sessionState === "ready"
        phoneFocused: root.opened && !root.settingsOpen
                      && root.phonePreview !== null
                      && root.phonePreview.inputFocused
        onKeyRequested: function(key) {
            pairingState.sendKeyInput(key)
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
        contentWidth: panel.fittedContentWidth(root.desiredPanelWidth())
        contentHeight: panel.fittedContentHeight(content.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: manualCode.activeFocus
                     || (root.phonePreview !== null
                         && root.phonePreview.inputFocused)
            onActivateRequested: root.activatePrimary()
            onCloseRequested: root.close()
            onTextKey: function(text) {
                pairingState.sendTextInput(text)
            }

            Column {
                id: content
                width: parent.width
                spacing: Style.space(12)

                PanelHero {
                    width: parent.width
                    visible: pairingState.sessionState !== "ready"
                    title: root.settingsOpen ? "Render settings" : pairingState.statusTitle
                    meta: root.settingsOpen ? "Omarchy Android" : "Omarchy Android"
                    detail: root.settingsOpen ? "" : pairingState.sessionState
                    foreground: root.contentForeground
                }

                Text {
                    visible: pairingState.sessionState !== "ready" && !root.settingsOpen
                    width: parent.width
                    text: pairingState.statusDescription
                    color: Qt.darker(root.contentForeground, 1.25)
                    font.family: Style.fontFamily
                    font.pixelSize: Style.fontBaseSize
                    wrapMode: Text.Wrap
                }
                PhoneToolbar {
                    width: parent.width
                    visible: pairingState.sessionState === "ready"
                    actions: pairingState.quickActions
                    settingsOpen: root.settingsOpen
                    controlsEnabled: pairingState.sessionState === "ready"
                    foreground: root.contentForeground
                    onActionRequested: function(action) {
                        root.runQuickAction(action)
                    }
                    onSettingsRequested: root.settingsOpen = true
                    onBackRequested: root.settingsOpen = false
                }

                Rectangle {
                    visible: pairingState.sessionState === "ready" && !root.settingsOpen
                    width: parent.width
                    height: root.desiredPreviewHeight(panel.availableCardHeight)
                    color: "transparent"
                    radius: Style.cornerRadius
                    clip: true
                    Loader {
                        id: phonePreviewLoader
                        anchors.centerIn: parent
                        width: root.desiredPreviewSize(panel.availableCardHeight).width
                        height: root.desiredPreviewSize(panel.availableCardHeight).height
                        active: parent.visible && root.opened
                        source: Qt.resolvedUrl("qml/components/PhonePreview.qml")
                        onLoaded: {
                            item.background = "black"
                            item.foreground = Qt.binding(function() {
                                return root.contentForeground
                            })
                            item.captureRequested = true
                            item.inputEnabled = Qt.binding(function() {
                                return root.opened && !root.settingsOpen
                            })
                        }
                    }

                    Connections {
                        target: phonePreviewLoader.item
                        enabled: target !== null
                        function onTapRequested(x, y, displayWidth, displayHeight) {
                            pairingState.sendPointerTap(x, y, displayWidth, displayHeight)
                        }
                        function onSwipeRequested(startX, startY, endX, endY,
                                                  displayWidth, displayHeight, durationMs) {
                            pairingState.sendPointerSwipe(startX, startY, endX, endY,
                                                         displayWidth, displayHeight, durationMs)
                        }
                        function onKeyRequested(key) {
                            pairingState.sendKeyInput(key)
                        }
                        function onTextRequested(text) {
                            pairingState.sendTextInput(text)
                        }
                    }
                }

                RenderSettings {
                    width: parent.width
                    visible: pairingState.sessionState === "ready" && root.settingsOpen
                    previewScale: pairingState.previewScale
                    videoQuality: pairingState.videoQuality
                    exactPhysicalScale: pairingState.physicalDisplayWidthMm > 0
                                        && pairingState.physicalDisplayHeightMm > 0
                    quickActions: pairingState.quickActions
                    foreground: root.contentForeground
                    onPreferencesRequested: function(scale, quality, actions) {
                        root.updateRenderPreferences(scale, quality, actions)
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
