import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "qml/PanelLifecycle.js" as PanelLifecycle
import "qml/state"
import "qml/components"
import "qml/PreviewGeometry.js" as PreviewGeometry

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
    property bool managementOpen: false
    property int helperEpochCounter: 0
    property string acceptedHelperEpoch: ""
    readonly property var helperLaunchCommand: helperCommand.concat(
                                                    ["--helper-epoch",
                                                     acceptedHelperEpoch])
    readonly property var barIdentity: hostWidget || root
    readonly property string applicationState: applicationStateModel.applicationState
    readonly property var popupPalette: Color.popups
    readonly property color contentForeground: popupPalette.text
    readonly property color contentBackground: popupPalette.background
    readonly property var phonePreview: phonePreviewLoader.item
    readonly property int setupSpacing: Style.space(12)
    readonly property int minimumQrSize: Style.space(180)
    readonly property int maximumQrSize: Style.space(240)
    readonly property real maximumContentHeight: Math.max(
                                                     1,
                                                     panel.availableCardHeight
                                                     - panel.verticalContentInset)
    readonly property real setupReservedHeight: setupHero.implicitHeight
                                                + setupDescription.implicitHeight
                                                + qrExpiry.implicitHeight
                                                + pairingActions.implicitHeight
                                                + setupSpacing * 4
    readonly property real setupQrSize: Math.min(
                                            content.width,
                                            maximumQrSize,
                                            Math.max(
                                                minimumQrSize,
                                                maximumContentHeight
                                                - setupReservedHeight))

    implicitWidth: 320
    implicitHeight: 480

    function horizontalPanelInset() {
        return panel.padding * 2 + Border.left(panel.borderSpec) + Border.right(panel.borderSpec);
    }

    function desiredViewportSize(availableHeight) {
        var horizontalInset = horizontalPanelInset();
        var reservedSpacing = phoneToolbar.visible ? 0 : content.spacing;
        var maxWidth = panel.availableCardWidth > 0 ? Math.max(1, panel.availableCardWidth - horizontalInset) : Style.space(288);
        var maxHeight = availableHeight > 0 ? Math.max(1, availableHeight - panel.verticalContentInset - phoneToolbar.implicitHeight - reservedSpacing) : Style.space(640);
        var sourceWidth = phonePreview && phonePreview.displayWidth > 0 ? phonePreview.displayWidth : 9;
        var sourceHeight = phonePreview && phonePreview.displayHeight > 0 ? phonePreview.displayHeight : 16;
        var baseWidth = Math.max(1, Style.space(320) - horizontalInset);
        return PreviewGeometry.scaledAspectSize(sourceWidth, sourceHeight, baseWidth, maxWidth, maxHeight, pairingState.previewScale);
    }

    function desiredPanelWidth() {
        if (root.applicationState === "interactive"
                || root.applicationState === "management"
                || pairingState.sessionStarted) {
            if (root.managementOpen)
                return Style.space(400);
            return horizontalPanelInset()
                    + Math.max(phoneToolbar.implicitWidth,
                               desiredViewportSize(
                                   panel.availableCardHeight).width);
        }
        return Style.space(320);
    }

    function desiredPreviewHeight(availableHeight) {
        return desiredViewportSize(availableHeight).height;
    }

    function openSettings() {
        managementOpen = true;
        settingsOpen = true;
        Qt.callLater(function () {
            phoneToolbar.forceSettingsFocus();
        });
    }

    function closeSettings() {
        settingsOpen = false;
        managementOpen = startOverDialog.opened;
    }

    function quickActionKey(action) {
        switch (action) {
        case "back": return "back";
        case "home": return "home";
        case "recent-apps": return "app-switch";
        default: return "";
        }
    }

    function runQuickAction(action) {
        if (root.applicationState !== "interactive")
            return;
        var key = quickActionKey(action);
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

    function updatePreferences(keepConnected, scale, quality, actions,
                               androidModeShortcuts) {
        pairingState.setPreferences(keepConnected, scale, quality, actions,
                                    androidModeShortcuts);
    }

    function helperCloseAction() {
        var sessionMayExist = pairingState.sessionStarted
                || pairingState.pairingStage === "connected"
                || pairingState.pairingStage === "session-starting"
                || pairingState.pairingStage === "session-started";
        return PanelLifecycle.closeAction(helperProcess.running, sessionMayExist,
                                          pairingState.keepConnected);
    }

    function requestStartOver() {
        if (!pairingState.helperReady || !pairingState.hasTrustedDevice
                || pairingState.startOverPending)
            return;
        managementOpen = true;
        startOverDialog.selectedIndex = 0;
        startOverDialog.opened = true;
        startOverDialog.forceActiveFocus();
    }

    function acceptPhoneTarget(request) {
        return phoneTargetRouter.acceptPhoneTarget(request);
    }

    function setScrcpyConfiguration(revision, arguments) {
        return pairingState.setScrcpyConfiguration(revision, arguments);
    }

    function requestClose() {
        submapController.closePanel();
    }

    function activatePrimary() {
        if (pairingState.pairingStage !== "manual-code")
            return;
        var code = manualCode.text;
        if (pairingState.submitManualCode(code))
            manualCode.text = "";
    }

    function launchHelper() {
        if (helperProcess.running)
            return;
        helperEpochCounter += 1;
        acceptedHelperEpoch = String(helperEpochCounter);
        submapController.helperRestarted();
        helperProcess.running = true;
    }

    function finishHelperShutdown() {
        if (!helperShutdownPending)
            return;
        helperShutdownPending = false;
        helperStopTimer.stop();
        helperProcess.running = false;
        acceptedHelperEpoch = "";
        pairingState.reset();
        submapController.helperRestarted();
    }

    onOpenedChanged: {
        if (opened) {
            helperShutdownPending = false;
            helperStopTimer.stop();
            launchHelper();
            pairingState.automaticPairingEnabled = true;
            if (pairingState.helperReady
                    && pairingState.sessionState === "unpaired")
                pairingState.startQrPairing();
        } else {
            submapController.helperRestarted();
            manualCode.text = "";
            startOverDialog.opened = false;
            pairingState.automaticPairingEnabled = false;
            var closeAction = helperCloseAction();
            if (closeAction === "stop-session"
                    || closeAction === "cancel-pairing") {
                helperShutdownPending = true;
                if (closeAction === "stop-session")
                    pairingState.stopSession();
                else
                    pairingState.cancelPairing();
                helperStopTimer.restart();
            }
            settingsOpen = false;
            managementOpen = false;
        }
    }

    ApplicationState {
        id: applicationStateModel
        objectName: "applicationStateModel"
        factsExternallyManaged: true
        panelOpen: root.opened
        managementOpen: root.managementOpen
        helperReady: pairingState.helperReady
        hasTrustedDevice: pairingState.hasTrustedDevice
        helperEpoch: root.acceptedHelperEpoch
        sessionGeneration: pairingState.sessionGeneration
        sessionStarted: pairingState.sessionStarted
        captureAvailable: root.phonePreview !== null
                              && root.phonePreview.captureAvailable
        captureActive: root.phonePreview !== null && root.phonePreview.active
        firstValidFrameReceived: root.phonePreview !== null
                                   && root.phonePreview.firstValidFrameReceived
        displayWidth: root.phonePreview !== null
                      ? root.phonePreview.displayWidth : 0
        displayHeight: root.phonePreview !== null
                       ? root.phonePreview.displayHeight : 0
        previewInputEnabled: root.phonePreview !== null
                             && root.phonePreview.previewInputEnabled
        helperActivity: pairingState.activity
        helperReason: pairingState.reason
    }

    PairingState {
        id: pairingState
        objectName: "pairingState"
        helperEpoch: root.acceptedHelperEpoch
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
            } else if (root.opened && pairingState.helperReady
                       && pairingState.sessionState === "unpaired") {
                pairingState.startQrPairing();
            }
        }
        onSessionStopConfirmed: {
            if (root.helperShutdownPending)
                root.finishHelperShutdown();
        }
        onPhoneTargetCompleted: function (requestId, outcome,
                                          notificationCode) {
            phoneTargetRouter.consumePhoneTargetResult(outcome,
                                                       notificationCode);
        }
        onPreferenceUpdateFailed: function (reason) {
            Quickshell.execDetached([
                "omarchy-notification-send",
                "Android settings could not be saved.",
                "--app-name", "omarchy-android",
                "-u", "normal",
                "--hint=boolean:transient:true"
            ]);
        }
        onLifecycleFailure: function (reason) {
            startOverDialog.opened = false;
            root.settingsOpen = false;
            root.managementOpen = false;
        }
    }

    PhoneTargetRouter {
        id: phoneTargetRouter
        applicationState: root.applicationState
        helperEpoch: root.acceptedHelperEpoch
        sessionGeneration: pairingState.sessionGeneration
        onPhoneTargetRequested: function (request) {
            pairingState.sendPhoneTarget(request.requestId, request.target,
                                         request.expiresAtUnixMs);
        }
        onPhoneTargetFailureNotificationRequested: function (message,
                                                               coalesceKey) {
            Quickshell.execDetached([
                "omarchy-notification-send", message,
                "--app-name", "omarchy-android",
                "-u", "normal",
                "--hint=boolean:transient:true"
            ]);
        }
    }

    SubmapController {
        id: submapController
        applicationState: root.applicationState
        androidModeShortcuts: pairingState.androidModeShortcuts
        onSubmapCommandRequested: function (command, submap) {
            submapProcess.running = false;
            submapProcess.dispatchedSubmap = submap;
            submapProcess.command = command;
            submapProcess.running = true;
        }
        onPanelCloseRequested: root.close()
    }

    Process {
        id: submapProcess
        property string dispatchedSubmap: "reset"
        running: false
    }
    Connections {
        target: submapProcess
        function onExited(exitCode) {
            if (exitCode === 0)
                return;
            pairingState.localIntegrationFailure();
            if (submapProcess.dispatchedSubmap === "reset") {
                submapResetRetry.restart();
            } else {
                submapController.dispatchFailed();
            }
        }
    }

    Timer {
        id: submapResetRetry
        interval: 1000
        repeat: false
        onTriggered: submapController.forceReset()
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
        command: root.helperLaunchCommand
        stdinEnabled: true
        running: false
        stdout: SplitParser {
            onRead: function (data) {
                pairingState.receiveLine(data);
            }
        }
        onRunningChanged: {
            if (!running && root.acceptedHelperEpoch !== "") {
                root.acceptedHelperEpoch = "";
                submapController.helperRestarted();
                if (root.opened)
                    pairingState.protocolFailure();
            }
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
            blocked: root.settingsOpen || startOverDialog.opened
                     || manualCode.activeFocus
                     || (root.phonePreview !== null
                         && root.phonePreview.inputFocused)
            onActivateRequested: root.activatePrimary()
            onCloseRequested: submapController.closePanel()
            onTextKey: function (text) {
                if (root.applicationState === "interactive")
                    pairingState.sendTextInput(text);
            }

            Column {
                id: content
                objectName: "panelContent"
                width: parent.width
                height: Math.min(implicitHeight, root.maximumContentHeight)
                spacing: root.setupSpacing

                Item {
                    id: setupHero
                    objectName: "setupHero"
                    width: parent.width
                    implicitHeight: setupHeadingLabels.implicitHeight
                    visible: (root.applicationState === "setup"
                              || root.applicationState === "recovering")
                             && !applicationStateModel.captureSurfaceRequired

                    Column {
                        id: setupHeadingLabels
                        width: parent.width
                        spacing: Style.space(2)

                        Item {
                            width: parent.width
                            height: Math.max(setupHeadingTitle.implicitHeight,
                                             setupHeadingTagSurface.implicitHeight)

                            Text {
                                id: setupHeadingTitle
                                objectName: "setupHeadingTitle"
                                anchors.left: parent.left
                                anchors.right: setupHeadingTagSurface.left
                                anchors.rightMargin: setupHeadingTagSurface.visible
                                                     ? Style.space(8) : 0
                                anchors.verticalCenter: parent.verticalCenter
                                text: pairingState.statusTitle
                                color: root.contentForeground
                                font.family: Style.fontFamily
                                font.pixelSize: Style.font.title
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            BorderSurface {
                                id: setupHeadingTagSurface
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                implicitWidth: setupHeadingTag.implicitWidth
                                               + Style.space(10)
                                implicitHeight: setupHeadingTag.implicitHeight
                                                + Style.space(4)
                                color: "transparent"
                                borderSpec: Border.controlSpec(
                                                "normal",
                                                root.contentForeground,
                                                Color.accent)
                                radius: Style.cornerRadius

                                Text {
                                    id: setupHeadingTag
                                    objectName: "setupHeadingTag"
                                    anchors.centerIn: parent
                                    text: pairingState.sessionState
                                          === "dependency-unavailable"
                                          ? "Unavailable"
                                          : pairingState.sessionState
                                    color: Qt.darker(root.contentForeground,
                                                     1.4)
                                    font.family: Style.fontFamily
                                    font.pixelSize: Style.font.body
                                    font.bold: true
                                }
                            }
                        }

                        Text {
                            id: setupHeadingMeta
                            objectName: "setupHeadingMeta"
                            width: parent.width
                            text: "DROID PEEK"
                            color: Qt.darker(root.contentForeground, 1.4)
                            font.family: Style.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 1.2
                            elide: Text.ElideRight
                        }
                    }
                }

                Text {
                    id: setupDescription
                    objectName: "setupDescription"
                    visible: (root.applicationState === "setup"
                              || root.applicationState === "recovering")
                             && !root.settingsOpen
                             && !applicationStateModel.captureSurfaceRequired
                    width: parent.width
                    text: pairingState.statusDescription
                    color: root.contentForeground
                    font.family: Style.fontFamily
                    font.pixelSize: Style.fontBaseSize
                    wrapMode: Text.Wrap
                }

                Column {
                    id: interactivePhoneUnit
                    objectName: "interactivePhoneUnit"
                    width: parent.width
                    spacing: 0
                    visible: root.applicationState === "interactive"
                             || root.settingsOpen
                             || applicationStateModel.captureSurfaceRequired

                    PhoneToolbar {
                        id: phoneToolbar
                        objectName: "phoneToolbar"
                        width: parent.width
                        height: visible ? implicitHeight : 0
                        visible: root.applicationState === "interactive"
                                 || root.settingsOpen
                        bar: root.bar
                        foreground: root.contentForeground
                        actions: pairingState.quickActions
                        keepConnected: pairingState.keepConnected
                        settingsOpen: root.settingsOpen
                        applicationState: root.applicationState
                        onActionRequested: function (action) {
                            root.runQuickAction(action);
                        }
                        onSettingsRequested: root.openSettings()
                        onBackRequested: root.closeSettings()
                        onKeepConnectedRequested: function (keepConnected) {
                            root.updatePreferences(
                                        keepConnected,
                                        pairingState.previewScale,
                                        pairingState.videoQuality,
                                        pairingState.quickActions,
                                        pairingState.androidModeShortcuts);
                        }
                    }

                    Item {
                        id: previewCard
                        objectName: "previewCard"
                        visible: applicationStateModel.captureSurfaceRequired
                        width: parent.width
                        height: root.desiredPreviewHeight(
                                    panel.availableCardHeight)
                        clip: true

                        Rectangle {
                            id: previewCardBackground
                            objectName: "previewCardBackground"
                            x: 0
                            y: -radius
                            width: parent.width
                            height: parent.height + radius
                            color: root.contentBackground
                            radius: Style.cornerRadius
                        }

                        Loader {
                            id: phonePreviewLoader
                            anchors.centerIn: parent
                            width: root.desiredViewportSize(
                                       panel.availableCardHeight).width
                            height: root.desiredViewportSize(
                                        panel.availableCardHeight).height
                            active: root.opened
                                    && pairingState.sessionStarted
                            source: Qt.resolvedUrl(
                                        "qml/components/PhonePreview.qml")
                            onLoaded: {
                                item.background = Qt.binding(function () {
                                    return root.contentBackground;
                                });
                                item.foreground = Qt.binding(function () {
                                    return root.contentForeground;
                                });
                                item.captureRequested = Qt.binding(function () {
                                    return root.opened
                                            && pairingState.sessionStarted;
                                });
                                item.helperEpoch = Qt.binding(function () {
                                    return root.acceptedHelperEpoch;
                                });
                                item.sessionGeneration = Qt.binding(function () {
                                    return pairingState.sessionGeneration;
                                });
                                item.applicationState = Qt.binding(function () {
                                    return root.applicationState;
                                });
                                item.inputEnabled = Qt.binding(function () {
                                    return root.opened && !root.managementOpen;
                                });
                            }
                        }

                        Item {
                            id: previewLoadingTreatment
                            objectName: "previewLoadingTreatment"
                            anchors.centerIn: parent
                            implicitWidth: loadingGlyph.implicitWidth
                            implicitHeight: loadingGlyph.implicitHeight
                            visible: applicationStateModel.captureSurfaceRequired
                                     && !applicationStateModel.previewUsable
                            property bool running: visible
                            property color foreground: root.contentForeground

                            Text {
                                id: loadingGlyph
                                anchors.centerIn: parent
                                text: "󰦖"
                                color: previewLoadingTreatment.foreground
                                font.family: Style.fontFamily
                                font.pixelSize: Style.font.body

                                RotationAnimator on rotation {
                                    running: previewLoadingTreatment.running
                                    from: 0
                                    to: 360
                                    duration: 800
                                    loops: Animation.Infinite
                                }
                            }
                        }

                        Connections {
                            target: phonePreviewLoader.item
                            enabled: target !== null

                            function onFirstValidFrameReceivedChanged() {
                                var preview = phonePreviewLoader.item;
                                if (!preview
                                        || !preview.firstValidFrameReceived)
                                    return;
                                Qt.callLater(function () {
                                    if (root.applicationState
                                            === "interactive")
                                        pairingState
                                        .requestScreenOffAfterPreview(
                                            preview.helperEpoch,
                                            preview.sessionGeneration);
                                });
                            }
                            function onTapRequested(x, y, displayWidth,
                                                    displayHeight, helperEpoch,
                                                    sessionGeneration) {
                                if (helperEpoch === root.acceptedHelperEpoch
                                        && sessionGeneration
                                           === pairingState.sessionGeneration)
                                    pairingState.sendPointerTap(
                                                x, y, displayWidth,
                                                displayHeight);
                            }
                            function onSwipeRequested(startX, startY, endX,
                                                      endY, displayWidth,
                                                      displayHeight,
                                                      durationMs, helperEpoch,
                                                      sessionGeneration) {
                                if (helperEpoch === root.acceptedHelperEpoch
                                        && sessionGeneration
                                           === pairingState.sessionGeneration)
                                    pairingState.sendPointerSwipe(
                                                startX, startY, endX, endY,
                                                displayWidth, displayHeight,
                                                durationMs);
                            }
                            function onKeyRequested(key, helperEpoch,
                                                    sessionGeneration) {
                                if (helperEpoch === root.acceptedHelperEpoch
                                        && sessionGeneration
                                           === pairingState.sessionGeneration)
                                    pairingState.sendKeyInput(key);
                            }
                            function onTextRequested(text, helperEpoch,
                                                     sessionGeneration) {
                                if (helperEpoch === root.acceptedHelperEpoch
                                        && sessionGeneration
                                           === pairingState.sessionGeneration)
                                    pairingState.sendTextInput(text);
                            }
                        }
                    }
                }

                Settings {
                    id: settingsView
                    width: parent.width
                    maximumHeight: Math.max(
                                       1, panel.availableCardHeight
                                       - panel.verticalContentInset
                                       - phoneToolbar.implicitHeight
                                       - content.spacing)
                    visible: root.applicationState === "management"
                             && root.settingsOpen
                    keepConnected: pairingState.keepConnected
                    previewScale: pairingState.previewScale
                    videoQuality: pairingState.videoQuality
                    quickActions: pairingState.quickActions
                    androidModeShortcuts: pairingState.androidModeShortcuts
                    foreground: root.contentForeground
                    onBackRequested: root.closeSettings()
                    onPreferencesRequested: function (keepConnected, scale,
                                                       quality, actions,
                                                       androidModeShortcuts) {
                        root.updatePreferences(keepConnected, scale, quality,
                                               actions,
                                               androidModeShortcuts);
                    }
                    onStartOverRequested: root.requestStartOver()
                }

                Rectangle {
                    id: pairingQr
                    objectName: "pairingQr"
                    visible: pairingState.pairingStage === "qr-waiting" && pairingState.qrArtifact !== ""
                    width: root.setupQrSize
                    height: root.setupQrSize
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
                    id: qrExpiry
                    objectName: "qrExpiry"
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
                    objectName: "manualCodeField"
                    width: parent.width
                    visible: pairingState.pairingStage === "manual-code"
                    placeholderText: "Pairing code"
                    inputMethodHints: Qt.ImhDigitsOnly
                    maximumLength: 6
                    foreground: root.contentForeground
                    onAccepted: root.activatePrimary()
                }

                Row {
                    id: pairingActions
                    objectName: "pairingActions"
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(8)
                    Button {
                        objectName: "pairByCodeButton"
                        visible: pairingState.pairingStage === "qr-waiting"
                        text: "Pair by code"
                        foreground: root.contentForeground
                        focusable: true
                        onClicked: pairingState.useManualCode()
                    }

                    Button {
                        objectName: "pairButton"
                        visible: pairingState.pairingStage === "manual-code"
                        text: "Pair"
                        foreground: root.contentForeground
                        focusable: true
                        onClicked: root.activatePrimary()
                    }

                    Button {
                        visible: pairingState.sessionState === "disconnected"
                        text: "Reconnect"
                        foreground: root.contentForeground
                        onClicked: pairingState.reconnectTrustedDevice()
                    }
                    Button {
                        objectName: "fallbackStartOverButton"
                        visible: pairingState.helperReady
                                 && pairingState.hasTrustedDevice
                                 && root.applicationState !== "interactive"
                                 && !applicationStateModel.captureSurfaceRequired
                                 && !root.settingsOpen
                                 && !pairingState.startOverPending
                        text: pairingState.pairingStage === "start-over-failed" ? "Retry start over" : "Start over"
                        foreground: root.contentForeground
                        onClicked: root.requestStartOver()
                    }
                }
            }

            ConfirmDialog {
                id: startOverDialog
                objectName: "startOverDialog"
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
                    root.managementOpen = root.settingsOpen;
                    keyCatcher.forceActiveFocus();
                }
                onConfirmed: {
                    if (!pairingState.startOver())
                        return;
                    opened = false;
                    root.settingsOpen = false;
                    root.managementOpen = false;
                    keyCatcher.forceActiveFocus();
                }
            }
        }
    }
}
