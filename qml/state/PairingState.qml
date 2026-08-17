import QtQuick

QtObject {
    id: root

    readonly property int protocolVersion: 8
    property bool helperReady: false
    property bool automaticPairingEnabled: true
    property bool hasTrustedDevice: false
    property bool startOverPending: false
    property string sessionState: "unpaired"
    property string pairingStage: "idle"
    property string statusTitle: "Preparing QR code"
    property string statusDescription: "Open Wireless debugging on your phone."
    property string qrArtifact: ""
    property int qrExpiresInSeconds: 0
    property bool keepConnected: false
    property int previewScale: 100
    property string videoQuality: "high"
    property var quickActions: ["back", "home", "recent-apps"]
    property bool androidModeShortcuts: false

    signal commandRequested(string command)
    signal pairingCancellationConfirmed()
    signal sessionStopConfirmed()
    signal startOverConfirmed()
    signal semanticActionCompleted(string actionId, string requestId, bool handled)

    function reset() {
        helperReady = false
        hasTrustedDevice = false
        startOverPending = false
        sessionState = "unpaired"
        pairingStage = "idle"
        statusTitle = "Preparing QR code"
        statusDescription = "Open Wireless debugging on your phone."
        keepConnected = false
        previewScale = 100
        videoQuality = "high"
        quickActions = ["back", "home", "recent-apps"]
        androidModeShortcuts = false
        clearQrPresentation()
    }

    function clearQrPresentation() {
        qrArtifact = ""
        qrExpiresInSeconds = 0
    }

    function tickQrExpiry() {
        if (pairingStage === "qr-waiting" && qrExpiresInSeconds > 0)
            qrExpiresInSeconds--
    }

    function sendCommand(command) {
        command.version = protocolVersion
        commandRequested(JSON.stringify(command))
    }

    function startQrPairing() {
        clearQrPresentation()
        sendCommand({ type: "start-qr-pairing" })
    }

    function reconnectTrustedDevice() {
        clearQrPresentation()
        sendCommand({ type: "reconnect-trusted-device" })
    }

    function useManualCode() {
        clearQrPresentation()
        sendCommand({ type: "use-manual-code" })
    }

    function submitManualCode(code) {
        if (String(code).trim() === "") {
            statusDescription = "Enter the pairing code shown by Android."
            return
        }
        sendCommand({ type: "submit-manual-code", code: String(code) })
    }

    function cancelPairing() {
        sendCommand({ type: "cancel-pairing" })
    }

    function stopSession() {
        sendCommand({ type: "stop-session" })
    }

    function startOver() {
        if (!helperReady || !hasTrustedDevice || startOverPending)
            return
        startOverPending = true
        clearQrPresentation()
        sessionState = "pairing"
        pairingStage = "starting-over"
        statusTitle = "Starting over"
        statusDescription = "Stopping this session and forgetting the trusted phone."
        sendCommand({ type: "start-over" })
    }

    function sendPointerTap(x, y, displayWidth, displayHeight) {
        sendCommand({
            type: "pointer-tap",
            x: x,
            y: y,
            displayWidth: displayWidth,
            displayHeight: displayHeight
        })
    }

    function sendPointerSwipe(startX, startY, endX, endY,
                              displayWidth, displayHeight, durationMs) {
        sendCommand({
            type: "pointer-swipe",
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            durationMs: durationMs
        })
    }

    function sendKeyInput(key) {
        sendCommand({ type: "key-input", key: key })
    }

    function sendTextInput(text) {
        sendCommand({ type: "text-input", text: text })
    }

    function validActionRequestId(requestId) {
        return typeof requestId === "string"
                && /^[A-Za-z0-9-]{1,64}$/.test(requestId)
    }

    function validActionDeadline(expiresAtUnixMs) {
        return typeof expiresAtUnixMs === "number"
                && isFinite(expiresAtUnixMs)
                && expiresAtUnixMs > 0
                && Math.floor(expiresAtUnixMs) === expiresAtUnixMs
                && expiresAtUnixMs > Date.now()
    }

    function sendSemanticAction(actionId, requestId, expiresAtUnixMs) {
        if ((actionId !== "omarchy-close-current-window"
                && actionId !== "omarchy-browser")
                || !validActionRequestId(requestId)
                || !validActionDeadline(expiresAtUnixMs))
            return false
        sendCommand({
                        type: "semantic-action",
                        actionId: actionId,
                        requestId: requestId,
                        expiresAtUnixMs: expiresAtUnixMs
                    })
        return true
    }

    function validPreference(value, allowed) {
        return typeof value === "string" && allowed.indexOf(value) >= 0
    }

    function validPreviewScale(value) {
        return typeof value === "number"
                && value >= 50 && value <= 150
                && Math.floor(value) === value
    }


    function applyPreferences(preferences) {
        if (!preferences
                || typeof preferences.keepConnected !== "boolean"
                || typeof preferences.androidModeShortcuts !== "boolean"
                || !validPreviewScale(preferences.previewScale)
                || !validPreference(preferences.videoQuality, ["low", "medium", "high"])
                || !Array.isArray(preferences.quickActions)
                || preferences.quickActions.length !== 3) {
            return false
        }
        for (var index = 0; index < preferences.quickActions.length; ++index) {
            if (!validPreference(preferences.quickActions[index],
                                 ["back", "home", "recent-apps"]))
                return false
        }
        keepConnected = preferences.keepConnected
        previewScale = preferences.previewScale
        videoQuality = preferences.videoQuality
        quickActions = preferences.quickActions.slice()
        androidModeShortcuts = preferences.androidModeShortcuts
        return true
    }

    function setPreferences(keepConnectedValue, scale, quality, actions, androidModeShortcutsValue) {
        var preferences = {
            keepConnected: keepConnectedValue,
            previewScale: scale,
            videoQuality: quality,
            quickActions: actions,
            androidModeShortcuts: androidModeShortcutsValue
        }
        if (!applyPreferences(preferences))
            return false
        sendCommand({
            type: "set-preferences",
            keepConnected: keepConnected,
            previewScale: previewScale,
            videoQuality: videoQuality,
            quickActions: quickActions,
            androidModeShortcuts: androidModeShortcuts
        })
        return true
    }

    function protocolFailure() {
        startOverPending = false
        clearQrPresentation()
        sessionState = "dependency-unavailable"
        pairingStage = "protocol-error"
        statusTitle = "Android helper unavailable"
        statusDescription = "The local helper returned an unsupported response. Recheck the plugin installation."
    }

    function applyFailure(reason) {
        if (startOverPending) {
            startOverPending = false
            clearQrPresentation()
            sessionState = "dependency-unavailable"
            pairingStage = "start-over-failed"
            statusTitle = "Couldn’t start over"
            statusDescription = "The trusted phone is still remembered. Retry or close this panel."
            return
        }
        clearQrPresentation()
        pairingStage = "failed"
        if (reason === "pairing-rejected") {
            sessionState = "unauthorized"
            statusTitle = "Pairing rejected"
            statusDescription = "Check the pairing code or generate a fresh QR code, then retry."
        } else if (reason === "unauthorized") {
            sessionState = "unauthorized"
            statusTitle = "Authorization required"
            statusDescription = "Approve Wireless debugging on the phone, then retry."
        } else if (reason === "disconnected" || reason === "network-unavailable") {
            sessionState = "disconnected"
            statusTitle = "Phone unavailable"
            statusDescription = "Check that the phone is on the same trusted Wi-Fi network, then reconnect."
        } else if (reason === "dependency-unavailable") {
            sessionState = "dependency-unavailable"
            statusTitle = "Local dependency unavailable"
            statusDescription = "Recheck the documented Omarchy Android dependencies."
        } else {
            protocolFailure()
        }
    }

    function receiveLine(line) {
        var event
        try {
            event = JSON.parse(String(line))
        } catch (error) {
            protocolFailure()
            return
        }

        if (!event || event.version !== protocolVersion || typeof event.type !== "string") {
            protocolFailure()
            return
        }

        switch (event.type) {
        case "ready":
            if (typeof event.hasTrustedDevice !== "boolean"
                    || !applyPreferences(event.preferences)) {
                protocolFailure()
                return
            }
            helperReady = true
            hasTrustedDevice = event.hasTrustedDevice
            if (event.hasTrustedDevice)
                reconnectTrustedDevice()
            else if (automaticPairingEnabled && sessionState === "unpaired")
                startQrPairing()
            return
        case "preferences-updated":
            if (typeof event.sessionRestarted !== "boolean"
                    || !applyPreferences(event)) {
                protocolFailure()
                return
            }
            if (event.sessionRestarted) {
                sessionState = "pairing"
                pairingStage = "session-starting"
                statusTitle = "Updating video quality"
                statusDescription = "Restarting the private phone stream."
            }
            return
        case "qr-waiting":
            if (typeof event.artifact !== "string"
                    || event.artifact.charAt(0) !== "/"
                    || typeof event.expiresInSeconds !== "number"
                    || event.expiresInSeconds <= 0) {
                protocolFailure()
                return
            }
            qrArtifact = event.artifact
            qrExpiresInSeconds = Math.floor(event.expiresInSeconds)
            sessionState = "qr-waiting"
            pairingStage = "qr-waiting"
            statusTitle = "Scan with your phone"
            statusDescription = "Open Wireless debugging and scan the pairing QR code."
            return
        case "pairing":
            clearQrPresentation()
            sessionState = "pairing"
            pairingStage = "pairing"
            statusTitle = "Pairing phone"
            statusDescription = "Keep Wireless debugging open while the secure pairing completes."
            return
        case "qr-timed-out":
            clearQrPresentation()
            sessionState = "qr-waiting"
            pairingStage = "starting"
            statusTitle = "Refreshing QR code"
            statusDescription = "Keep Wireless debugging open."
            startQrPairing()
            return
        case "pairing-cancelled":
            clearQrPresentation()
            sessionState = "unpaired"
            pairingStage = "cancelled"
            pairingCancellationConfirmed()
            statusTitle = "Pairing cancelled"
            statusDescription = "Start again when the phone is ready."
            return
        case "manual-code-required":
            clearQrPresentation()
            sessionState = "qr-waiting"
            pairingStage = "manual-code"
            statusTitle = "Pair by code"
            statusDescription = "Enter the pairing code shown in Wireless debugging."
            return
        case "connecting":
            clearQrPresentation()
            sessionState = "pairing"
            pairingStage = "connecting"
            statusTitle = "Connecting phone"
            statusDescription = "Finding the trusted phone on this Wi-Fi network."
            return
        case "connected":
        case "paired":
            hasTrustedDevice = true
            clearQrPresentation()
            sessionState = "pairing"
            pairingStage = "connected"
            statusTitle = "Starting phone view"
            statusDescription = "The trusted phone is connected. Starting the private mirror."
            return
        case "session-starting":
            sessionState = "pairing"
            pairingStage = "session-starting"
            statusTitle = "Starting phone view"
            statusDescription = "Preparing the private scrcpy video session."
            return
        case "session-started":
            sessionState = "ready"
            pairingStage = "session-started"
            statusTitle = "Phone connected"
            statusDescription = "The trusted phone session is active."
            return
        case "session-ended":
            sessionState = "disconnected"
            pairingStage = "session-ended"
            statusTitle = "Phone session ended"
            statusDescription = "Reconnect to start a new phone session."
            return
        case "session-stopped":
            sessionStopConfirmed()
            return
        case "start-over-complete":
            clearQrPresentation()
            startOverPending = false
            hasTrustedDevice = false
            sessionState = "unpaired"
            pairingStage = "starting"
            statusTitle = "Preparing QR code"
            statusDescription = "Open Wireless debugging on the phone you want to pair."
            startOverConfirmed()
            if (automaticPairingEnabled)
                startQrPairing()
            return
        case "action-result":
            if ((event.actionId !== "omarchy-close-current-window"
                    && event.actionId !== "omarchy-browser")
                    || !validActionRequestId(event.requestId)
                    || typeof event.handled !== "boolean") {
                protocolFailure()
                return
            }
            semanticActionCompleted(event.actionId, event.requestId, event.handled)
            return
        case "failure":
            applyFailure(event.reason)
            return
        case "protocol-error":
            protocolFailure()
            return
        default:
            protocolFailure()
        }
    }
}
