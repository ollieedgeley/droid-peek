import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "qml/PanelLifecycle.js" as PanelLifecycle
import "qml/state"
import "qml/components"
import "qml/PreviewGeometry.js" as PreviewGeometry
import "qml"

Panel {
    id: root

    moduleName: "ollieedgeley.droidpeek"
    ipcTarget: "ollieedgeley.droidpeek"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    readonly property string helperExecutable: {
        var home = Quickshell.env("HOME");
        return home ? home + "/.local/bin/droid-peek-helper" : "";
    }
    readonly property var helperCommand: helperExecutable === "" ? [] : [helperExecutable, "--acceptance-log"]
    property bool helperShutdownPending: false
    property bool helperIntentionalStop: false
    property bool retainedClosePending: false
    property var retainedClosePreview: null
    property int retainedCloseCaptureEpoch: -1
    property string retainedCloseHelperEpoch: ""
    property string retainedCloseSessionGeneration: ""
    property int presentationClaimSerial: 0
    property int retainedClosePresentationSerial: -1
    property bool settingsOpen: false
    property bool managementOpen: false
    property int helperEpochCounter: 0
    property string acceptedHelperEpoch: ""
    readonly property var barIdentity: hostWidget || root
    readonly property string applicationState: applicationStateModel.applicationState
    readonly property var popupPalette: Color.popups
    readonly property color contentForeground: popupPalette.text
    readonly property color contentBackground: popupPalette.background
    readonly property PhonePreview phonePreview: phonePreviewLoader.item as PhonePreview
    readonly property var fontTokens: Style.font
    readonly property bool retainMountedPreview: pairingState.keepConnected && pairingState.sessionStarted && pairingState.previewReadyGeneration !== "" && pairingState.previewReadyGeneration === pairingState.sessionGeneration
    readonly property bool previewCaptureWanted: pairingState.sessionStarted && (root.opened || root.retainMountedPreview)
    readonly property int setupSpacing: Style.space(12)
    readonly property int minimumQrSize: Style.space(180)
    readonly property int maximumQrSize: Style.space(240)
    readonly property real maximumContentHeight: Math.max(1, panel.availableCardHeight - panel.verticalContentInset)
    readonly property real setupReservedHeight: setupHero.implicitHeight + setupDescription.implicitHeight + qrExpiry.implicitHeight + pairingActions.implicitHeight + setupSpacing * 4
    readonly property real setupQrSize: Math.min(content.width, maximumQrSize, Math.max(minimumQrSize, maximumContentHeight - setupReservedHeight))

    implicitWidth: 320
    implicitHeight: 480

    function horizontalPanelInset() {
        return panel.padding * 2 + Border.left(panel.borderSpec) + Border.right(panel.borderSpec);
    }
    readonly property int previewSourceWidth: phonePreview !== null && phonePreview.framedWidth > 0 ? phonePreview.framedWidth : (phonePreview !== null && phonePreview.displayWidth > 0 ? phonePreview.displayWidth : 9)
    readonly property int previewSourceHeight: phonePreview !== null && phonePreview.framedHeight > 0 ? phonePreview.framedHeight : (phonePreview !== null && phonePreview.displayHeight > 0 ? phonePreview.displayHeight : 16)

    function desiredViewportSize(availableHeight) {
        var horizontalInset = horizontalPanelInset();
        var maxWidth = panel.availableCardWidth > 0 ? Math.max(1, panel.availableCardWidth - horizontalInset) : Style.space(288);
        var maxHeight = availableHeight > 0 ? Math.max(1, availableHeight - panel.verticalContentInset - phoneToolbar.implicitHeight) : Style.space(640);
        var baseWidth = Math.max(1, Style.space(320) - horizontalInset);
        return PreviewGeometry.scaledAspectSize(root.previewSourceWidth, root.previewSourceHeight, baseWidth, maxWidth, maxHeight, pairingState.previewScale);
    }

    function desiredPanelWidth() {
        if (root.applicationState === "interactive" || root.applicationState === "management" || applicationStateModel.captureSurfaceRequired) {
            if (root.managementOpen)
                return Style.space(400);
            return horizontalPanelInset() + desiredViewportSize(panel.availableCardHeight).width;
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
        case "back":
            return "back";
        case "home":
            return "home";
        case "recent-apps":
            return "app-switch";
        default:
            return "";
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

    function updatePreferences(keepConnected, scale, quality, actions, androidModeShortcuts) {
        pairingState.setPreferences(keepConnected, scale, quality, actions, androidModeShortcuts);
    }

    function helperCloseAction() {
        var sessionMayExist = pairingState.sessionStarted || pairingState.pairingStage === "connected" || pairingState.pairingStage === "session-starting" || pairingState.pairingStage === "session-started";
        return PanelLifecycle.closeAction(helperProcess.running, sessionMayExist, pairingState.keepConnected);
    }

    function requestStartOver() {
        if (!pairingState.helperReady || !pairingState.hasTrustedDevice || pairingState.startOverPending)
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

    function decodeEnvelope(encodedEnvelope, maximumLength) {
        if (typeof encodedEnvelope !== "string" || encodedEnvelope.length === 0 || encodedEnvelope.length > maximumLength || !/^[A-Za-z0-9_-]+$/.test(encodedEnvelope))
            return null;
        var base64 = encodedEnvelope.replace(/-/g, "+").replace(/_/g, "/");
        while (base64.length % 4 !== 0)
            base64 += "=";
        try {
            var binary = Qt.atob(base64);
            var escaped = "";
            for (var index = 0; index < binary.length; ++index)
                escaped += "%" + ("0" + binary.charCodeAt(index).toString(16)).slice(-2);
            return JSON.parse(decodeURIComponent(escaped));
        } catch (error) {
            return null;
        }
    }

    function phoneTarget(encodedEnvelope) {
        var request = decodeEnvelope(encodedEnvelope, 4096);
        if (request === null)
            return false;
        return acceptPhoneTarget(request);
    }

    function configureScrcpy(revision, encodedConfiguration) {
        var scrcpyArguments = decodeEnvelope(encodedConfiguration, 24000);
        if (scrcpyArguments === null)
            return false;
        return setScrcpyConfiguration(revision, scrcpyArguments);
    }

    function claimHost(widget, anchor, panelBar) {
        if (retainedClosePending)
            cancelRetainedCloseRequest();
        ++presentationClaimSerial;
        hostWidget = widget;
        anchorItem = anchor;
        root.bar = panelBar;
    }

    function clearRetainedCloseRequest() {
        retainedClosePending = false;
        retainedClosePreview = null;
        retainedCloseCaptureEpoch = -1;
        retainedCloseHelperEpoch = "";
        retainedCloseSessionGeneration = "";
        retainedClosePresentationSerial = -1;
    }

    function cancelRetainedCloseRequest() {
        var preview = retainedClosePreview;
        clearRetainedCloseRequest();
        if (preview !== null)
            preview.cancelPendingRetainedImageCapture();
    }

    function completeRetainedClose(retained, captureEpoch, helperEpoch, sessionGeneration) {
        var preview = retainedClosePreview;
        if (!retainedClosePending || preview === null || captureEpoch !== retainedCloseCaptureEpoch || helperEpoch !== retainedCloseHelperEpoch || sessionGeneration !== retainedCloseSessionGeneration)
            return;
        var pendingPresentationSerial = retainedClosePresentationSerial;
        clearRetainedCloseRequest();
        if (!root.opened || root.helperShutdownPending || root.presentationClaimSerial !== pendingPresentationSerial || root.phonePreview !== preview || preview.captureEpoch !== captureEpoch || preview.helperEpoch !== helperEpoch || preview.sessionGeneration !== sessionGeneration || root.acceptedHelperEpoch !== helperEpoch || pairingState.sessionGeneration !== sessionGeneration || !root.retainMountedPreview)
            return;
        submapController.closePanel();
    }

    function requestClose() {
        if (!root.opened)
            return;
        if (helperShutdownPending) {
            clearRetainedCloseRequest();
            submapController.closePanel();
            return;
        }
        if (retainedClosePending)
            return;
        var preview = phonePreview;
        if (!root.retainMountedPreview || preview === null || preview.retainedImageAvailable) {
            submapController.closePanel();
            return;
        }

        retainedClosePending = true;
        retainedClosePreview = preview;
        retainedCloseCaptureEpoch = preview.captureEpoch;
        retainedCloseHelperEpoch = preview.helperEpoch;
        retainedCloseSessionGeneration = preview.sessionGeneration;
        retainedClosePresentationSerial = root.presentationClaimSerial;
        if (!preview.captureRetainedImage()) {
            clearRetainedCloseRequest();
            submapController.closePanel();
        }
    }

    function teardownSession() {
        helperShutdownPending = true;
        if (opened)
            requestClose();
        finishHelperShutdown();
    }

    function activatePrimary() {
        if (pairingState.pairingStage !== "manual-code")
            return;
        var code = manualCode.text;
        if (pairingState.submitManualCode(code))
            manualCode.text = "";
    }

    function launchHelper() {
        if (helperProcess.running || helperVersionProcess.running)
            return;
        if (helperExecutable === "") {
            pairingState.protocolFailure();
            return;
        }
        helperVersionProcess.observedVersion = "";
        helperVersionProcess.running = true;
    }

    function startHelperAfterVersionCheck() {
        if (helperProcess.running)
            return;
        helperEpochCounter += 1;
        acceptedHelperEpoch = String(helperEpochCounter);
        submapController.helperRestarted();
        helperIntentionalStop = false;
        helperProcess.command = root.helperCommand.concat(["--helper-epoch", acceptedHelperEpoch]);
        helperProcess.running = true;
    }

    function finishHelperShutdown() {
        if (!helperShutdownPending)
            return;
        clearRetainedCloseRequest();
        helperShutdownPending = false;
        helperStopTimer.stop();
        if (helperVersionProcess.running)
            helperVersionProcess.running = false;
        helperVersionProcess.observedVersion = "";
        helperIntentionalStop = true;
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
            if (pairingState.helperReady && pairingState.sessionState === "unpaired")
                pairingState.startQrPairing();
        } else {
            if (retainedClosePending)
                cancelRetainedCloseRequest();
            if (helperVersionProcess.running)
                helperVersionProcess.running = false;
            helperVersionProcess.observedVersion = "";
            submapController.helperRestarted();
            manualCode.text = "";
            startOverDialog.opened = false;
            pairingState.automaticPairingEnabled = false;
            var closeAction = helperCloseAction();
            if (closeAction === "stop-session" || closeAction === "cancel-pairing") {
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

    BuildInfo {
        id: buildInfo
    }

    ApplicationState {
        id: applicationStateModel
        objectName: "applicationStateModel"
        panelOpen: root.opened
        managementOpen: root.managementOpen
        helperReady: pairingState.helperReady
        hasTrustedDevice: pairingState.hasTrustedDevice
        helperEpoch: root.acceptedHelperEpoch
        sessionGeneration: pairingState.sessionGeneration
        sessionStarted: pairingState.sessionStarted
        connectionPresentationActive: pairingState.connectionPresentationActive
        captureAvailable: root.phonePreview !== null && root.phonePreview.captureAvailable
        captureActive: root.phonePreview !== null && root.phonePreview.active
        retainedImageAvailable: root.phonePreview !== null && root.phonePreview.retainedImageAvailable
        firstValidFrameReceived: root.phonePreview !== null && root.phonePreview.firstValidFrameReceived
        displayWidth: root.phonePreview !== null ? root.phonePreview.displayWidth : 0
        displayHeight: root.phonePreview !== null ? root.phonePreview.displayHeight : 0
        previewInputEnabled: root.phonePreview !== null && root.phonePreview.previewInputEnabled
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
            } else if (root.opened && pairingState.helperReady && pairingState.sessionState === "unpaired") {
                pairingState.startQrPairing();
            }
        }
        onSessionStopConfirmed: {
            if (root.helperShutdownPending)
                root.finishHelperShutdown();
        }
        onPhoneTargetCompleted: function (requestId, outcome, notificationCode) {
            phoneTargetRouter.consumePhoneTargetResult(requestId, outcome, notificationCode);
        }
        onPreferenceUpdateFailed: function (reason) {
            Quickshell.execDetached(["omarchy-notification-send", "-g", "󰄜", "-u", "low", "Droid Peek", "Android settings could not be saved."]);
        }
        onLifecycleFailure: function (reason) {
            startOverDialog.opened = false;
            root.settingsOpen = false;
            root.managementOpen = false;
        }
    }

    Binding {
        target: pairingState
        property: "previewSurfaceMounted"
        value: phonePreviewLoader.active
    }

    PhoneTargetRouter {
        id: phoneTargetRouter
        applicationState: root.applicationState
        helperEpoch: root.acceptedHelperEpoch
        sessionGeneration: pairingState.sessionGeneration
        onPhoneTargetRequested: function (request) {
            pairingState.sendPhoneTarget(request.requestId, request.target, request.expiresAtUnixMs);
        }
        onPhoneTargetFailureNotificationRequested: function (message) {
            Quickshell.execDetached(["omarchy-notification-send", "-g", "󰄜", "-u", "low", "Droid Peek", message]);
        }
    }

    SubmapController {
        id: submapController
        objectName: "submapController"
        applicationState: root.applicationState
        androidModeShortcuts: pairingState.androidModeShortcuts
        onSubmapCommandRequested: function (command, submap, requestId) {
            if (submapProcess.running)
                submapProcess.running = false;
            submapProcess.dispatchedSubmap = submap;
            submapProcess.requestId = requestId;
            submapProcess.command = command;
            var started = submapProcess.startedRequests.slice();
            started.push({
                requestId: requestId,
                submap: submap
            });
            submapProcess.startedRequests = started;
            submapProcess.running = true;
        }
        onPanelCloseRequested: root.close()
    }

    Process {
        id: submapProcess
        objectName: "submapProcess"
        property string dispatchedSubmap: "reset"
        property int requestId: 0
        property var startedRequests: []
        running: false
    }
    Connections {
        target: submapProcess
        function onExited(exitCode) {
            var started = submapProcess.startedRequests.slice();
            if (started.length === 0)
                return;
            var completed = started.shift();
            submapProcess.startedRequests = started;
            if (!submapController.isCurrentRequest(completed.requestId))
                return;
            if (exitCode === 0)
                return;
            pairingState.localIntegrationFailure();
            if (completed.submap === "reset") {
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
        id: helperVersionProcess
        property string observedVersion: ""
        command: root.helperExecutable === "" ? [] : [root.helperExecutable, "--version"]
        running: false
        stdout: SplitParser {
            onRead: function (data) {
                helperVersionProcess.observedVersion = data;
            }
        }
    }
    Connections {
        target: helperVersionProcess
        function onExited(exitCode) {
            var version = helperVersionProcess.observedVersion;
            helperVersionProcess.observedVersion = "";
            if (!root.opened)
                return;
            if (exitCode !== 0 || version !== buildInfo.releaseVersion) {
                pairingState.protocolFailure();
                return;
            }
            root.startHelperAfterVersionCheck();
        }
    }

    Process {
        id: helperProcess
        stdinEnabled: true
        running: false
        stdout: SplitParser {
            onRead: function (data) {
                pairingState.receiveLine(data);
            }
        }

        onRunningChanged: {
            if (running) {
                root.helperIntentionalStop = false;
                return;
            }
            if (root.acceptedHelperEpoch === "")
                return;
            root.acceptedHelperEpoch = "";
            submapController.helperRestarted();
            if (root.helperIntentionalStop) {
                root.helperIntentionalStop = false;
                return;
            }
            if (root.opened)
                root.launchHelper();
        }
    }

    IpcHandler {
        target: "ollieedgeley.droidpeek"

        function phoneTarget(encodedEnvelope: string): bool {
            return root.phoneTarget(encodedEnvelope);
        }
        function configureScrcpy(revision: string, encodedConfiguration: string): bool {
            return root.configureScrcpy(revision, encodedConfiguration);
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
            onCloseRequested: root.requestClose()
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
                    visible: (root.applicationState === "setup" || root.applicationState === "recovering") && !applicationStateModel.captureSurfaceRequired

                    Column {
                        id: setupHeadingLabels
                        width: parent.width
                        spacing: Style.space(2)

                        Item {
                            width: parent.width
                            height: Math.max(setupHeadingTitle.implicitHeight, setupHeadingTagSurface.implicitHeight)

                            Text {
                                id: setupHeadingTitle
                                objectName: "setupHeadingTitle"
                                anchors.left: parent.left
                                anchors.right: setupHeadingTagSurface.left
                                anchors.rightMargin: setupHeadingTagSurface.visible ? Style.space(8) : 0
                                anchors.verticalCenter: parent.verticalCenter
                                text: pairingState.statusTitle
                                color: root.contentForeground
                                font.family: Style.fontFamily
                                font.pixelSize: root.fontTokens.title
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            BorderSurface {
                                id: setupHeadingTagSurface
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                implicitWidth: setupHeadingTag.implicitWidth + Style.space(10)
                                implicitHeight: setupHeadingTag.implicitHeight + Style.space(4)
                                color: "transparent"
                                borderSpec: Border.controlSpec("normal", root.contentForeground, Color.accent)
                                radius: Style.cornerRadius

                                Text {
                                    id: setupHeadingTag
                                    objectName: "setupHeadingTag"
                                    anchors.centerIn: parent
                                    text: pairingState.pairingStage === "local-integration-failed" ? "Shortcuts" : pairingState.sessionState === "dependency-unavailable" ? "Unavailable" : pairingState.sessionState
                                    color: Qt.darker(root.contentForeground, 1.4)
                                    font.family: Style.fontFamily
                                    font.pixelSize: root.fontTokens.body
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
                            font.pixelSize: root.fontTokens.caption
                            font.bold: true
                            font.letterSpacing: 1.2
                            elide: Text.ElideRight
                        }
                    }
                }

                Text {
                    id: setupDescription
                    objectName: "setupDescription"
                    visible: (root.applicationState === "setup" || root.applicationState === "recovering") && !root.settingsOpen && !applicationStateModel.captureSurfaceRequired
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
                    width: root.settingsOpen ? parent.width : root.desiredViewportSize(panel.availableCardHeight).width
                    x: root.settingsOpen || parent === null ? 0 : Math.round((parent.width - width) / 2)
                    spacing: 0
                    visible: root.applicationState === "interactive" || root.settingsOpen || applicationStateModel.captureSurfaceRequired

                    Item {
                        objectName: "loadingToolbarSpacer"
                        width: parent.width
                        height: visible ? phoneToolbar.implicitHeight : 0
                        visible: !phoneToolbar.visible
                    }

                    PhoneToolbar {
                        id: phoneToolbar
                        objectName: "phoneToolbar"
                        width: parent.width
                        height: visible ? implicitHeight : 0
                        visible: root.applicationState === "interactive" || root.settingsOpen || (applicationStateModel.captureSurfaceRequired && applicationStateModel.retainedImageAvailable)
                        enabled: root.applicationState === "interactive" || root.settingsOpen
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
                            root.updatePreferences(keepConnected, pairingState.previewScale, pairingState.videoQuality, pairingState.quickActions, pairingState.androidModeShortcuts);
                        }
                    }

                    Item {
                        id: previewCard
                        objectName: "previewCard"
                        visible: applicationStateModel.captureSurfaceRequired
                        width: parent.width
                        height: root.desiredPreviewHeight(panel.availableCardHeight)
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
                            anchors.fill: parent
                            active: root.previewCaptureWanted
                            sourceComponent: PhonePreview {}
                            onLoaded: {
                                item.background = Qt.binding(function () {
                                    return root.contentBackground;
                                });
                                item.foreground = Qt.binding(function () {
                                    return root.contentForeground;
                                });
                                item.captureRequested = Qt.binding(function () {
                                    return root.previewCaptureWanted;
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
                            visible: applicationStateModel.captureSurfaceRequired && !applicationStateModel.previewPresentationUsable
                            property bool running: visible
                            property color foreground: root.contentForeground

                            Text {
                                id: loadingGlyph
                                anchors.centerIn: parent
                                text: "󰦖"
                                color: previewLoadingTreatment.foreground
                                font.family: Style.fontFamily
                                font.pixelSize: root.fontTokens.body

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
                            target: root.phonePreview
                            enabled: target !== null

                            function onFirstValidFrameReceivedChanged() {
                                var preview = root.phonePreview;
                                if (!preview || !preview.firstValidFrameReceived)
                                    return;
                                pairingState.acknowledgePreviewReady(preview.helperEpoch, preview.sessionGeneration);
                            }
                            function onRetainedImageCaptureCompleted(retained, captureEpoch, helperEpoch, sessionGeneration) {
                                root.completeRetainedClose(retained, captureEpoch, helperEpoch, sessionGeneration);
                            }
                            function onTapRequested(x, y, displayWidth, displayHeight, helperEpoch, sessionGeneration) {
                                if (helperEpoch === root.acceptedHelperEpoch && sessionGeneration === pairingState.sessionGeneration)
                                    pairingState.sendPointerTap(x, y, displayWidth, displayHeight);
                            }
                            function onSwipeRequested(startX, startY, endX, endY, displayWidth, displayHeight, durationMs, helperEpoch, sessionGeneration) {
                                if (helperEpoch === root.acceptedHelperEpoch && sessionGeneration === pairingState.sessionGeneration)
                                    pairingState.sendPointerSwipe(startX, startY, endX, endY, displayWidth, displayHeight, durationMs);
                            }
                            function onKeyRequested(key, helperEpoch, sessionGeneration) {
                                if (helperEpoch === root.acceptedHelperEpoch && sessionGeneration === pairingState.sessionGeneration)
                                    pairingState.sendKeyInput(key);
                            }
                            function onTextRequested(text, helperEpoch, sessionGeneration) {
                                if (helperEpoch === root.acceptedHelperEpoch && sessionGeneration === pairingState.sessionGeneration)
                                    pairingState.sendTextInput(text);
                            }
                        }
                    }
                }

                Settings {
                    id: settingsView
                    width: parent.width
                    maximumHeight: Math.max(1, panel.availableCardHeight - panel.verticalContentInset - phoneToolbar.implicitHeight - content.spacing)
                    visible: root.applicationState === "management" && root.settingsOpen
                    keepConnected: pairingState.keepConnected
                    previewScale: pairingState.previewScale
                    videoQuality: pairingState.videoQuality
                    quickActions: pairingState.quickActions
                    androidModeShortcuts: pairingState.androidModeShortcuts
                    foreground: root.contentForeground
                    onBackRequested: root.closeSettings()
                    onPreferencesRequested: function (keepConnected, scale, quality, actions, androidModeShortcuts) {
                        root.updatePreferences(keepConnected, scale, quality, actions, androidModeShortcuts);
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
                        objectName: "reconnectButton"
                        visible: (pairingState.sessionState === "disconnected" || pairingState.pairingStage === "local-integration-failed") && !applicationStateModel.captureSurfaceRequired
                        text: "Reconnect"
                        foreground: root.contentForeground
                        onClicked: {
                            pairingState.retryLocalIntegration();
                            pairingState.reconnectTrustedDevice();
                        }
                    }
                    Button {
                        objectName: "fallbackStartOverButton"
                        visible: pairingState.helperReady && root.opened && pairingState.hasTrustedDevice && root.applicationState !== "interactive" && !applicationStateModel.captureSurfaceRequired && !root.settingsOpen && !pairingState.startOverPending
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
                message: "Start over with a new device?\n\n" + "This stops the current session and forgets this device " + "on this computer. It does not remove this computer " + "from Android’s Paired devices list."
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
