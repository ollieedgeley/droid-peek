import QtQuick

QtObject {
    id: root

    readonly property int protocolVersion: 1
    property bool helperReady: false
    property bool automaticPairingEnabled: true
    property string sessionState: "unpaired"
    property string pairingStage: "idle"
    property string statusTitle: "Preparing QR code"
    property string statusDescription: "Open Wireless debugging on your phone."
    property string qrArtifact: ""
    property int qrExpiresInSeconds: 0
    property string previewSize: "medium"
    property string videoQuality: "high"
    property var quickActions: ["back", "home", "recent-apps"]

    signal commandRequested(string command)
    signal pairingCancellationConfirmed()
    signal sessionStopConfirmed()

    function reset() {
        helperReady = false
        sessionState = "unpaired"
        pairingStage = "idle"
        statusTitle = "Preparing QR code"
        statusDescription = "Open Wireless debugging on your phone."
        previewSize = "medium"
        videoQuality = "high"
        quickActions = ["back", "home", "recent-apps"]
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

    function validPreference(value, allowed) {
        return typeof value === "string" && allowed.indexOf(value) >= 0
    }

    function applyPreferences(preferences) {
        if (!preferences
                || !validPreference(preferences.previewSize, ["small", "medium", "large"])
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
        previewSize = preferences.previewSize
        videoQuality = preferences.videoQuality
        quickActions = preferences.quickActions.slice()
        return true
    }

    function setRenderPreferences(size, quality, actions) {
        var preferences = {
            previewSize: size,
            videoQuality: quality,
            quickActions: actions
        }
        if (!applyPreferences(preferences))
            return false
        sendCommand({
            type: "set-render-preferences",
            previewSize: previewSize,
            videoQuality: videoQuality,
            quickActions: quickActions
        })
        return true
    }

    function protocolFailure() {
        clearQrPresentation()
        sessionState = "dependency-unavailable"
        pairingStage = "protocol-error"
        statusTitle = "Android helper unavailable"
        statusDescription = "The local helper returned an unsupported response. Recheck the plugin installation."
    }

    function applyFailure(reason) {
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
            if (event.hasTrustedDevice)
                reconnectTrustedDevice()
            else if (automaticPairingEnabled && sessionState === "unpaired")
                startQrPairing()
            return
        case "preferences-updated":
            if (!applyPreferences(event)
                    || typeof event.sessionRestarted !== "boolean") {
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
