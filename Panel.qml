import QtQuick
import QtQuick.Window
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "qml/state"
import "qml/components"
import "qml/PreviewGeometry.js" as PreviewGeometry
import "qml/PanelLifecycle.js" as PanelLifecycle

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
    readonly property color contentBackground: Color.background
    readonly property var phonePreview: phonePreviewLoader.item

    implicitWidth: 320
    implicitHeight: 480

    function horizontalPanelInset() {
        return panel.padding * 2 + Border.left(panel.borderSpec) + Border.right(panel.borderSpec);
    }

    function desiredViewportSize(availableHeight) {
        var horizontalInset = horizontalPanelInset();
        var maxWidth = panel.availableCardWidth > 0 ? Math.max(1, panel.availableCardWidth - horizontalInset) : Style.space(288);
        var maxHeight = availableHeight > 0 ? Math.max(1, availableHeight - panel.verticalContentInset - phoneToolbar.implicitHeight - content.spacing) : Style.space(640);
        var sourceWidth = phonePreview && phonePreview.displayWidth > 0 ? phonePreview.displayWidth : 9;
        var sourceHeight = phonePreview && phonePreview.displayHeight > 0 ? phonePreview.displayHeight : 16;
        var baseWidth = Math.max(1, Style.space(320) - horizontalInset);
        return PreviewGeometry.scaledAspectSize(sourceWidth, sourceHeight, baseWidth, maxWidth, maxHeight, pairingState.previewScale);
    }

    function desiredPanelWidth() {
        if (pairingState.sessionState === "ready") {
            if (root.settingsOpen)
                return Style.space(400);
            return horizontalPanelInset() + Math.max(phoneToolbar.implicitWidth, desiredViewportSize(panel.availableCardHeight).width);
        }
        return Style.space(320);
    }

    function desiredPreviewHeight(availableHeight) {
        return desiredViewportSize(availableHeight).height;
    }

    function openSettings() {
        settingsOpen = true;
        Qt.callLater(function () {
            phoneToolbar.forceSettingsFocus();
        });
    }

    function closeSettings() {
        settingsOpen = false;
    }

    function runQuickAction(action) {
        var key = semanticActionRouter.quickActionKey(action);
        if (key === "")
            return;
        pairingState.sendKeyInput(key);
        if (phonePreview) {
            Qt.callLater(function () {
                if (root.phonePreview)
                    root.phonePreview.forceActiveFocus();
            });
        }
    }

    function updatePreferences(keepConnected, scale, quality, actions, androidModeShortcuts, commandPassthrough) {
        pairingState.setPreferences(keepConnected, scale, quality, actions, androidModeShortcuts, commandPassthrough);
    }

    function requestStartOver() {
        if (!pairingState.helperReady || !pairingState.hasTrustedDevice || pairingState.startOverPending)
            return;
        startOverDialog.selectedIndex = 0;
        startOverDialog.opened = true;
        startOverDialog.forceActiveFocus();
    }

    function triggerSemanticAction(actionId, requestId, expiresAtUnixMs, actionArgument) {
        return semanticActionRouter.trigger(actionId, requestId, expiresAtUnixMs, actionArgument);
    }

    function activatePrimary() {
        if (pairingState.pairingStage !== "manual-code")
            return;
        var code = manualCode.text;
        if (pairingState.submitManualCode(code))
            manualCode.text = "";
    }

    function finishHelperShutdown() {
        if (!helperShutdownPending)
            return;
        helperShutdownPending = false;
        helperStopTimer.stop();
        helperProcess.running = false;
        pairingState.reset();
    }

    onOpenedChanged: {
        if (opened) {
            helperShutdownPending = false;
            helperStopTimer.stop();
            helperProcess.running = true;
            pairingState.automaticPairingEnabled = true;
            if (pairingState.helperReady && pairingState.sessionState === "unpaired")
                pairingState.startQrPairing();
        } else {
            manualCode.text = "";
            startOverDialog.opened = false;
            pairingState.automaticPairingEnabled = false;
            var closeAction = PanelLifecycle.closeAction(pairingState.keepConnected, pairingState.sessionState, pairingState.pairingStage, helperProcess.running);
            if (closeAction === "stop-session" || closeAction === "cancel-pairing") {
                helperShutdownPending = true;
                if (closeAction === "stop-session")
                    pairingState.stopSession();
                else
                    pairingState.cancelPairing();
                helperStopTimer.restart();
            }
            settingsOpen = false;
        }
    }

    PairingState {
        id: pairingState
        onCommandRequested: function (command) {
            if (!helperProcess.running) {
                pairingState.protocolFailure();
                return;
            }
            helperProcess.write(command + "\n");
        }
        onPairingCancellationConfirmed: {
            if (root.helperShutdownPending) {
                root.finishHelperShutdown();
            } else if (root.opened && pairingState.helperReady && pairingState.sessionState === "unpaired") {
                pairingState.startQrPairing();
            }
        }
        onSessionStopConfirmed: {
            if (root.helperShutdownPending)
                root.finishHelperShutdown();
        }
    }

    SemanticActionRouter {
        id: semanticActionRouter
        semanticIntegrationEnabled: pairingState.androidModeShortcuts
        commandPassthrough: pairingState.commandPassthrough
        sessionReady: pairingState.sessionState === "ready"
        panelOpen: root.opened
        settingsOpen: root.settingsOpen
        phoneVisible: root.phonePreview !== null && root.phonePreview.visible
        phoneEnabled: root.phonePreview !== null && root.phonePreview.inputActive
        phoneFocused: root.phonePreview !== null && root.phonePreview.inputFocused
        phoneInteractionReady: root.phonePreview !== null && root.phonePreview.interactionReady
        onKeyRequested: function (key) {
            pairingState.sendKeyInput(key);
        }
        onSemanticActionRequested: function (actionId, requestId, expiresAtUnixMs, actionArgument) {
            pairingState.sendSemanticAction(actionId, requestId, expiresAtUnixMs, actionArgument);
        }
    }

    ShortcutInhibitor {
        window: panel
        enabled: semanticActionRouter.shortcutInhibitionRequested
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
        running: root.opened && pairingState.pairingStage === "qr-waiting" && pairingState.qrExpiresInSeconds > 0
        onTriggered: pairingState.tickQrExpiry()
    }

    Process {
        id: helperProcess
        command: root.helperCommand
        stdinEnabled: true
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                pairingState.receiveLine(line);
            }
        }
        onRunningChanged: {
            if (!running && root.opened)
                pairingState.protocolFailure();
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
            blocked: root.settingsOpen || startOverDialog.opened || manualCode.activeFocus || (root.phonePreview !== null && root.phonePreview.inputFocused)
            onActivateRequested: root.activatePrimary()
            onCloseRequested: root.close()
            onTextKey: function (text) {
                pairingState.sendTextInput(text);
            }

            Column {
                id: content
                width: parent.width
                spacing: Style.space(12)

                PanelHero {
                    width: parent.width
                    visible: pairingState.sessionState !== "ready"
                    title: root.settingsOpen ? "Settings" : pairingState.statusTitle
                    meta: "Omarchy Android"
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
                    id: phoneToolbar
                    width: parent.width
                    visible: pairingState.sessionState === "ready"
                    actions: pairingState.quickActions
                    keepConnected: pairingState.keepConnected
                    settingsOpen: root.settingsOpen
                    controlsEnabled: pairingState.sessionState === "ready"
                    foreground: root.contentForeground
                    onActionRequested: function (action) {
                        root.runQuickAction(action);
                    }
                    onSettingsRequested: root.openSettings()
                    onBackRequested: root.closeSettings()
                    onKeepConnectedRequested: function (keepConnected) {
                        root.updatePreferences(keepConnected, pairingState.previewScale, pairingState.videoQuality, pairingState.quickActions, pairingState.androidModeShortcuts, pairingState.commandPassthrough);
                    }
                }

                Rectangle {
                    visible: pairingState.sessionState === "ready" && !root.settingsOpen
                    width: parent.width
                    height: root.desiredPreviewHeight(panel.availableCardHeight)
                    color: root.contentBackground
                    radius: Style.cornerRadius
                    clip: true
                    Loader {
                        id: phonePreviewLoader
                        anchors.centerIn: parent
                        width: root.desiredViewportSize(panel.availableCardHeight).width
                        height: root.desiredViewportSize(panel.availableCardHeight).height
                        active: parent.visible && root.opened
                        source: Qt.resolvedUrl("qml/components/PhonePreview.qml")
                        onLoaded: {
                            item.background = Qt.binding(function () {
                                return root.contentBackground;
                            });
                            item.foreground = Qt.binding(function () {
                                return root.contentForeground;
                            });
                            item.captureRequested = true;
                            item.inputEnabled = Qt.binding(function () {
                                return root.opened && !root.settingsOpen;
                            });
                        }
                    }

                    Connections {
                        target: phonePreviewLoader.item
                        enabled: target !== null
                        function onTapRequested(x, y, displayWidth, displayHeight) {
                            pairingState.sendPointerTap(x, y, displayWidth, displayHeight);
                        }
                        function onSwipeRequested(startX, startY, endX, endY, displayWidth, displayHeight, durationMs) {
                            pairingState.sendPointerSwipe(startX, startY, endX, endY, displayWidth, displayHeight, durationMs);
                        }
                        function onKeyRequested(key) {
                            pairingState.sendKeyInput(key);
                        }
                        function onTextRequested(text) {
                            pairingState.sendTextInput(text);
                        }
                    }
                }

                Settings {
                    id: settingsView
                    width: parent.width
                    maximumHeight: Math.max(1, panel.availableCardHeight - panel.verticalContentInset - phoneToolbar.implicitHeight - content.spacing)
                    visible: pairingState.sessionState === "ready" && root.settingsOpen
                    keepConnected: pairingState.keepConnected
                    previewScale: pairingState.previewScale
                    videoQuality: pairingState.videoQuality
                    quickActions: pairingState.quickActions
                    androidModeShortcuts: pairingState.androidModeShortcuts
                    commandPassthrough: pairingState.commandPassthrough
                    foreground: root.contentForeground
                    onBackRequested: root.closeSettings()
                    onPreferencesRequested: function (keepConnected, scale, quality, actions, androidModeShortcuts, commandPassthrough) {
                        root.updatePreferences(keepConnected, scale, quality, actions, androidModeShortcuts, commandPassthrough);
                    }
                    onStartOverRequested: root.requestStartOver()
                }

                Rectangle {
                    visible: pairingState.pairingStage === "qr-waiting" && pairingState.qrArtifact !== ""
                    width: Math.min(parent.width, Style.space(240))
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "white"
                    radius: Style.cornerRadius

                    Image {
                        anchors.fill: parent
                        anchors.margins: Style.space(10)
                        source: pairingState.qrArtifact === "" ? "" : "file://" + pairingState.qrArtifact
                        cache: false
                        fillMode: Image.PreserveAspectFit
                        smooth: false
                    }
                }

                Text {
                    visible: pairingState.pairingStage === "qr-waiting" && pairingState.qrArtifact !== ""
                    width: parent.width
                    text: pairingState.qrExpiresInSeconds === 1 ? "Expires in 1 second" : "Expires in " + pairingState.qrExpiresInSeconds + " seconds"
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
                    maximumLength: 6
                    onAccepted: root.activatePrimary()
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(8)
                    Button {
                        visible: pairingState.sessionState === "qr-waiting" && pairingState.pairingStage !== "manual-code"
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
                    Button {
                        visible: pairingState.helperReady && pairingState.hasTrustedDevice && pairingState.sessionState !== "ready" && !pairingState.startOverPending
                        text: pairingState.pairingStage === "start-over-failed" ? "Retry start over" : "Start over"
                        onClicked: root.requestStartOver()
                    }
                }
            }

            ConfirmDialog {
                id: startOverDialog
                anchors.fill: parent
                z: 10
                message: "Start over with a new phone?\n\n" + "This stops the current session and forgets this phone " + "on this computer. It does not remove this computer " + "from Android’s Paired devices list."
                cancelText: "Cancel"
                confirmText: "Start over"
                background: root.contentBackground
                foreground: root.contentForeground
                focus: opened

                Keys.onPressed: function (event) {
                    if (handleKey(event))
                        event.accepted = true;
                }

                onCanceled: {
                    opened = false;
                    keyCatcher.forceActiveFocus();
                }
                onConfirmed: {
                    opened = false;
                    root.settingsOpen = false;
                    pairingState.startOver();
                    keyCatcher.forceActiveFocus();
                }
            }
        }
    }
}
