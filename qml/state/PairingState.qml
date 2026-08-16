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

    signal commandRequested(string command)
    signal pairingCancellationConfirmed()

    function reset() {
        helperReady = false
        sessionState = "unpaired"
        pairingStage = "idle"
        statusTitle = "Preparing QR code"
        statusDescription = "Open Wireless debugging on your phone."
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
            helperReady = true
            if (automaticPairingEnabled && sessionState === "unpaired")
                startQrPairing()
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
        case "paired":
            clearQrPresentation()
            sessionState = "ready"
            pairingStage = "paired"
            statusTitle = "Phone paired"
            statusDescription = "The trusted phone is ready to connect."
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
