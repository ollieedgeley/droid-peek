import QtQuick

QtObject {
    id: root

    readonly property int protocolVersion: 11
    property string helperEpoch: ""
    property string sessionGeneration: ""
    property bool helperReady: false
    property bool automaticPairingEnabled: true
    property bool hasTrustedDevice: false
    property bool sessionStarted: false
    property bool startOverPending: false
    property string startOverGeneration: ""
    property bool localIntegrationAvailable: true
    property string sessionState: "unpaired"
    property string pairingStage: "idle"
    property string activity: ""
    property string reason: ""
    property string statusTitle: "Preparing QR code"
    property string statusDescription: "Open Wireless debugging on your phone."
    property string qrArtifact: ""
    property int qrExpiresInSeconds: 0
    property bool keepConnected: false
    property int previewScale: 100
    property string videoQuality: "high"
    property var quickActions: ["back", "home", "recent-apps"]
    property bool androidModeShortcuts: true

    signal commandRequested(string command)
    signal pairingCancellationConfirmed()
    signal sessionStopConfirmed()
    signal phoneTargetCompleted(string requestId, string outcome, string notificationCode)
    signal lifecycleFailure(string reason)
    signal preferenceUpdateFailed(string reason)

    function resetHelperFacts() {
        helperReady = false;
        sessionGeneration = "";
        sessionStarted = false;
        startOverPending = false;
        startOverGeneration = "";
        localIntegrationAvailable = true;
        sessionState = hasTrustedDevice ? "disconnected" : "unpaired";
        pairingStage = "idle";
        activity = "";
        reason = "";
        statusTitle = hasTrustedDevice ? "Reconnecting phone" : "Preparing QR code";
        statusDescription = hasTrustedDevice
                ? "Restarting the local helper for the trusted phone."
                : "Open Wireless debugging on your phone.";
        clearQrPresentation();
    }

    function reset() {
        resetHelperFacts();
        keepConnected = false;
        previewScale = 100;
        videoQuality = "high";
        quickActions = ["back", "home", "recent-apps"];
        androidModeShortcuts = true;
    }

    onHelperEpochChanged: resetHelperFacts()

    function clearQrPresentation() {
        qrArtifact = "";
        qrExpiresInSeconds = 0;
    }

    function clearSessionFacts() {
        sessionStarted = false;
    }

    function tickQrExpiry() {
        if (pairingStage === "qr-waiting" && qrExpiresInSeconds > 0)
            qrExpiresInSeconds--;
    }

    function isDecimalIdentity(value) {
        return typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value);
    }

    function nextDecimal(value) {
        var digits = value.split("");
        var carry = 1;
        for (var index = digits.length - 1; index >= 0 && carry; --index) {
            var digit = digits[index].charCodeAt(0) - 48 + carry;
            digits[index] = String(digit % 10);
            carry = digit > 9 ? 1 : 0;
        }
        if (carry)
            digits.unshift("1");
        return digits.join("");
    }

    function sendCommand(command) {
        if (!isDecimalIdentity(helperEpoch))
            return false;
        command.version = protocolVersion;
        command.helperEpoch = helperEpoch;
        commandRequested(JSON.stringify(command));
        return true;
    }

    function sendGenerationCommand(command) {
        if (!helperReady || !isDecimalIdentity(sessionGeneration))
            return false;
        command.sessionGeneration = sessionGeneration;
        return sendCommand(command);
    }

    function sendSessionCommand(command) {
        if (!sessionStarted || sessionGeneration === "0")
            return false;
        return sendGenerationCommand(command);
    }

    function startQrPairing() {
        clearQrPresentation();
        return sendCommand({ type: "start-qr-pairing" });
    }
    function reconnectTrustedDevice() {
        clearQrPresentation();
        return sendCommand({ type: "reconnect-trusted-device" });
    }

    function useManualCode() {
        clearQrPresentation();
        return sendCommand({ type: "use-manual-code" });
    }

    function submitManualCode(code) {
        var submittedCode = String(code);
        if (!/^[0-9]{6}$/.test(submittedCode)) {
            statusDescription = "Enter the six-digit pairing code shown by Android.";
            return false;
        }
        return sendCommand({ type: "submit-manual-code", code: submittedCode });
    }

    function cancelPairing() {
        return sendCommand({ type: "cancel-pairing" });
    }

    function stopSession() {
        return sendSessionCommand({ type: "stop-session" });
    }

    function startOver() {
        if (!helperReady || !hasTrustedDevice || startOverPending
                || !isDecimalIdentity(helperEpoch)
                || !isDecimalIdentity(sessionGeneration))
            return false;
        startOverPending = true;
        startOverGeneration = sessionGeneration;
        hasTrustedDevice = false;
        clearQrPresentation();
        clearSessionFacts();
        sessionState = "stopping";
        pairingStage = "starting-over";
        activity = "stopping";
        statusTitle = "Starting over";
        statusDescription = "Stopping this session and forgetting the trusted phone.";
        return sendGenerationCommand({ type: "start-over" });
    }

    function sendPointerTap(x, y, displayWidth, displayHeight) {
        return sendSessionCommand({
            type: "pointer-tap", x: x, y: y,
            displayWidth: displayWidth, displayHeight: displayHeight
        });
    }

    function sendPointerSwipe(startX, startY, endX, endY,
                              displayWidth, displayHeight, durationMs) {
        return sendSessionCommand({
            type: "pointer-swipe", startX: startX, startY: startY,
            endX: endX, endY: endY, displayWidth: displayWidth,
            displayHeight: displayHeight, durationMs: durationMs
        });
    }

    function sendKeyInput(key) {
        return sendSessionCommand({ type: "key-input", key: key });
    }

    function sendTextInput(text) {
        return sendSessionCommand({ type: "text-input", text: text });
    }

    function validActionRequestId(requestId) {
        return typeof requestId === "string"
                && /^[A-Za-z0-9-]{1,64}$/.test(requestId);
    }

    function sendPhoneTarget(requestId, target, expiresAtUnixMs) {
        var targetHasSafeShape = typeof target === "string"
                || (target !== null && typeof target === "object"
                    && !Array.isArray(target));
        if (!validActionRequestId(requestId)
                || !targetHasSafeShape
                || typeof expiresAtUnixMs !== "number"
                || !isFinite(expiresAtUnixMs))
            return false;
        return sendSessionCommand({
            type: "phone-target", requestId: requestId, target: target,
            expiresAtUnixMs: expiresAtUnixMs
        });
    }

    function validPreference(value, allowed) {
        return typeof value === "string" && allowed.indexOf(value) >= 0;
    }

    function validPreviewScale(value) {
        return typeof value === "number" && value >= 50 && value <= 150
                && Math.floor(value) === value;
    }
    function hasOnlyPreferenceKeys(preferences, eventEnvelope) {
        var allowed = [
            "keepConnected", "previewScale", "videoQuality",
            "quickActions", "androidModeShortcuts"
        ];
        if (eventEnvelope) {
            allowed = allowed.concat([
                "version", "type", "helperEpoch", "sessionGeneration",
                "sessionRestarted"
            ]);
        }
        var keys = Object.keys(preferences);
        for (var index = 0; index < keys.length; ++index) {
            if (allowed.indexOf(keys[index]) < 0)
                return false;
        }
        return true;
    }


    function validPreferences(preferences, eventEnvelope) {
        if (!preferences || !hasOnlyPreferenceKeys(preferences, eventEnvelope)
                || typeof preferences.keepConnected !== "boolean"
                || typeof preferences.androidModeShortcuts !== "boolean"
                || !validPreviewScale(preferences.previewScale)
                || !validPreference(preferences.videoQuality,
                                    ["low", "medium", "high"])
                || !Array.isArray(preferences.quickActions)
                || preferences.quickActions.length !== 3)
            return false;
        for (var index = 0; index < preferences.quickActions.length; ++index) {
            if (!validPreference(preferences.quickActions[index],
                                 ["back", "home", "recent-apps"]))
                return false;
        }
        return true;
    }

    function applyPreferences(preferences, eventEnvelope) {
        if (!validPreferences(preferences, eventEnvelope))
            return false;
        keepConnected = preferences.keepConnected;
        previewScale = preferences.previewScale;
        videoQuality = preferences.videoQuality;
        quickActions = preferences.quickActions.slice();
        androidModeShortcuts = preferences.androidModeShortcuts;
        return true;
    }

    function setPreferences(keepConnectedValue, scale, quality, actions,
                            androidModeShortcutsValue) {
        var preferences = {
            keepConnected: keepConnectedValue,
            previewScale: scale,
            videoQuality: quality,
            quickActions: actions,
            androidModeShortcuts: androidModeShortcutsValue
        };
        if (!validPreferences(preferences))
            return false;
        return sendCommand({
            type: "set-preferences",
            keepConnected: preferences.keepConnected,
            previewScale: preferences.previewScale,
            videoQuality: preferences.videoQuality,
            quickActions: preferences.quickActions.slice(),
            androidModeShortcuts: preferences.androidModeShortcuts
        });
    }

    function protocolFailure() {
        helperReady = false;
        sessionGeneration = "";
        startOverPending = false;
        startOverGeneration = "";
        clearQrPresentation();
        clearSessionFacts();
        sessionState = "dependency-unavailable";
        pairingStage = "protocol-error";
        activity = "";
        reason = "dependency-unavailable";
        statusTitle = "Android helper unavailable";
        statusDescription = "The local helper returned an unsupported response. Recheck the plugin installation.";
        lifecycleFailure(reason);
    }

    function localIntegrationFailure() {
        helperReady = false;
        sessionGeneration = "";
        startOverPending = false;
        startOverGeneration = "";
        localIntegrationAvailable = false;
        clearQrPresentation();
        clearSessionFacts();
        sessionState = "dependency-unavailable";
        pairingStage = "local-integration-failed";
        activity = "";
        reason = "dependency-unavailable";
        statusTitle = "Android keyboard controls unavailable";
        statusDescription = "The desktop shortcut mode could not be activated.";
        lifecycleFailure(reason);
    }

    function advanceGeneration(generation) {
        if (!isDecimalIdentity(sessionGeneration)
                || generation !== nextDecimal(sessionGeneration))
            return false;
        sessionGeneration = generation;
        clearSessionFacts();
        activity = "";
        reason = "";
        return true;
    }

    function admitCurrentGeneration(event, mayAdvance) {
        if (!isDecimalIdentity(event.sessionGeneration))
            return false;
        if (event.sessionGeneration === sessionGeneration)
            return sessionGeneration !== "0";
        return mayAdvance && advanceGeneration(event.sessionGeneration);
    }

    function admitInvalidatingGeneration(event) {
        return isDecimalIdentity(event.sessionGeneration)
                && advanceGeneration(event.sessionGeneration);
    }

    function admitSessionStopped(event) {
        if (!isDecimalIdentity(event.sessionGeneration))
            return false;
        if (event.sessionGeneration === sessionGeneration)
            return sessionGeneration !== "0" && !sessionStarted;
        return advanceGeneration(event.sessionGeneration);
    }

    function validFailureReason(failureReason) {
        return typeof failureReason === "string"
                && ["dependency-unavailable", "unauthorized", "disconnected",
                    "network-unavailable", "pairing-rejected"].indexOf(
                        failureReason) >= 0;
    }

    function admitStartOverComplete(event) {
        if (!isDecimalIdentity(startOverGeneration)
                || event.sessionGeneration !== nextDecimal(startOverGeneration))
            return false;
        if (event.sessionGeneration === sessionGeneration)
            return !sessionStarted;
        return advanceGeneration(event.sessionGeneration);
    }

    function setConnectionPresentation(stage, nextActivity, title, description) {
        clearQrPresentation();
        sessionState = "connecting";
        pairingStage = stage;
        activity = nextActivity;
        reason = "";
        statusTitle = title;
        statusDescription = description;
    }

    function applyLifecycleFailure(failureReason) {
        startOverPending = false;
        startOverGeneration = "";
        clearQrPresentation();
        clearSessionFacts();
        activity = "";
        reason = failureReason;
        pairingStage = "failed";
        if (failureReason === "unauthorized") {
            sessionState = "unauthorized";
            statusTitle = "Authorization required";
            statusDescription = "Approve Wireless debugging on the phone, then retry.";
        } else if (failureReason === "disconnected"
                   || failureReason === "network-unavailable") {
            sessionState = "disconnected";
            statusTitle = "Phone unavailable";
            statusDescription = "Check that the phone is on the same trusted Wi-Fi network, then reconnect.";
        } else {
            sessionState = "dependency-unavailable";
            statusTitle = "Local dependency unavailable";
            statusDescription = "Recheck the documented Omarchy Android dependencies.";
        }
        lifecycleFailure(failureReason);
    }

    function receiveLine(line) {
        var event;
        try {
            event = JSON.parse(String(line));
        } catch (error) {
            protocolFailure();
            return;
        }
        if (!event || !isDecimalIdentity(event.helperEpoch)
                || event.helperEpoch !== helperEpoch)
            return;
        if (event.version !== protocolVersion || typeof event.type !== "string") {
            protocolFailure();
            return;
        }
        if (!localIntegrationAvailable)
            return;
        if (startOverPending
                && ["session-ended", "session-stopped",
                    "start-over-complete", "lifecycle-failure", "failure",
                    "action-result", "protocol-error"].indexOf(event.type) < 0)
            return;

        switch (event.type) {
        case "ready":
            if (event.sessionGeneration !== "0" || helperReady
                    || sessionGeneration !== "")
                return;
            if (typeof event.hasTrustedDevice !== "boolean"
                    || !applyPreferences(event.preferences)) {
                protocolFailure();
                return;
            }
            helperReady = true;
            hasTrustedDevice = event.hasTrustedDevice;
            sessionGeneration = "0";
            sessionStarted = false;
            sessionState = hasTrustedDevice ? "disconnected" : "unpaired";
            if (hasTrustedDevice)
                reconnectTrustedDevice();
            else if (automaticPairingEnabled)
                startQrPairing();
            return;
        case "preferences-updated":
            if (!isDecimalIdentity(event.sessionGeneration))
                return;
            if (event.sessionRestarted === true) {
                if (!isDecimalIdentity(sessionGeneration)
                        || event.sessionGeneration !== nextDecimal(sessionGeneration))
                    return;
            } else if (event.sessionRestarted === false) {
                if (event.sessionGeneration !== sessionGeneration)
                    return;
            } else if (event.sessionGeneration !== sessionGeneration
                       && (!isDecimalIdentity(sessionGeneration)
                           || event.sessionGeneration !== nextDecimal(sessionGeneration))) {
                return;
            }
            if (typeof event.sessionRestarted !== "boolean"
                    || !validPreferences(event, true)) {
                protocolFailure();
                return;
            }
            if (event.sessionRestarted)
                advanceGeneration(event.sessionGeneration);
            applyPreferences(event, true);
            if (event.sessionRestarted) {
                sessionState = "connecting";
                pairingStage = "session-starting";
                activity = "starting-preview";
                statusTitle = "Updating video quality";
                statusDescription = "Restarting the private phone stream.";
            }
            return;
        case "qr-waiting":
            if (typeof event.artifact !== "string" || event.artifact.charAt(0) !== "/"
                    || typeof event.expiresInSeconds !== "number"
                    || event.expiresInSeconds <= 0) {
                protocolFailure();
                return;
            }
            qrArtifact = event.artifact;
            qrExpiresInSeconds = Math.floor(event.expiresInSeconds);
            sessionState = "unpaired";
            pairingStage = "qr-waiting";
            activity = "qr-waiting";
            reason = "";
            statusTitle = "Scan with your phone";
            statusDescription = "Open Wireless debugging and scan the pairing QR code.";
            return;
        case "qr-timed-out":
            clearQrPresentation();
            pairingStage = "starting";
            activity = "starting-pairing";
            statusTitle = "Refreshing QR code";
            statusDescription = "Keep Wireless debugging open.";
            startQrPairing();
            return;
        case "pairing":
            clearQrPresentation();
            sessionState = "pairing";
            pairingStage = "pairing";
            activity = "pairing";
            reason = "";
            statusTitle = "Pairing phone";
            statusDescription = "Keep Wireless debugging open while the secure pairing completes.";
            return;
        case "manual-code-required":
            clearQrPresentation();
            pairingStage = "manual-code";
            activity = "manual-code";
            statusTitle = "Pair by code";
            statusDescription = "Enter the pairing code shown in Wireless debugging.";
            return;
        case "pairing-cancelled":
            clearQrPresentation();
            sessionState = "unpaired";
            pairingStage = "cancelled";
            activity = "pairing-cancelled";
            pairingCancellationConfirmed();
            statusTitle = "Pairing cancelled";
            statusDescription = "Start again when the phone is ready.";
            return;
        case "paired":
        case "connecting":
        case "connected":
        case "session-starting":
            if (startOverPending || !admitCurrentGeneration(event, true))
                return;
            hasTrustedDevice = true;
            if (event.type === "connecting")
                setConnectionPresentation("connecting", "connecting", "Connecting phone", "Finding the trusted phone on this Wi-Fi network.");
            else if (event.type === "session-starting")
                setConnectionPresentation("session-starting", "starting-preview", "Starting phone view", "Preparing the private scrcpy video session.");
            else
                setConnectionPresentation("connected", event.type === "paired" ? "connecting" : "connected", "Starting phone view", "The trusted phone is connected. Starting the private mirror.");
            return;
        case "session-started":
            if (startOverPending || !admitCurrentGeneration(event, false))
                return;
            hasTrustedDevice = true;
            sessionStarted = true;
            sessionState = "started";
            pairingStage = "session-started";
            activity = "";
            reason = "";
            statusTitle = "Phone connected";
            statusDescription = "The trusted phone session is active.";
            return;
        case "session-ended":
            if (!admitInvalidatingGeneration(event))
                return;
            sessionState = startOverPending ? "stopping" : "disconnected";
            pairingStage = startOverPending ? "starting-over" : event.type;
            activity = startOverPending ? "stopping" : "";
            reason = startOverPending ? "" : "disconnected";
            return;
        case "session-stopped":
            if (!admitSessionStopped(event))
                return;
            sessionState = startOverPending ? "stopping" : "disconnected";
            pairingStage = startOverPending ? "starting-over" : event.type;
            activity = startOverPending ? "stopping" : "";
            reason = "";
            sessionStopConfirmed();
            return;
        case "start-over-complete":
            if (!admitStartOverComplete(event))
                return;
            clearQrPresentation();
            startOverPending = false;
            hasTrustedDevice = false;
            startOverGeneration = "";
            sessionState = "unpaired";
            pairingStage = "starting";
            activity = "";
            reason = "";
            statusTitle = "Preparing QR code";
            statusDescription = "Open Wireless debugging on the phone you want to pair.";
            if (automaticPairingEnabled)
                startQrPairing();
            return;
        case "action-result":
            if (!admitCurrentGeneration(event, false)
                    || !validActionRequestId(event.requestId)
                    || ["completed", "failed",
                        "stale-session"].indexOf(event.outcome) < 0
                    || (event.notificationCode !== undefined
                        && ["invalid-target", "target-failed",
                            "target-timed-out",
                            "invalid-deadline"].indexOf(
                                event.notificationCode) < 0))
                return;
            phoneTargetCompleted(event.requestId, event.outcome,
                                 event.notificationCode || "");
            return;
        case "failure":
            if (event.sessionGeneration !== undefined
                    || !validFailureReason(event.reason))
                return;
            if (startOverPending) {
                startOverPending = false;
                startOverGeneration = "";
                hasTrustedDevice = true;
                sessionState = "disconnected";
                pairingStage = "failed";
                activity = "";
                reason = event.reason;
                statusTitle = "Start over failed";
                statusDescription = "The trusted phone was not forgotten. Retry Start over.";
                return;
            }
            if (sessionStarted || sessionGeneration !== "0") {
                preferenceUpdateFailed(event.reason);
                return;
            }
            if (event.reason === "pairing-rejected") {
                hasTrustedDevice = false;
                sessionState = "unpaired";
                pairingStage = "failed";
                activity = "";
                reason = "pairing-rejected";
                statusTitle = "Pairing rejected";
                statusDescription = "Check the pairing code or generate a fresh QR code, then retry.";
            } else {
                applyLifecycleFailure(event.reason);
            }
            return;
        case "lifecycle-failure":
            if (!validFailureReason(event.reason)
                    || !admitInvalidatingGeneration(event))
                return;
            applyLifecycleFailure(event.reason);
            return;
        case "protocol-error":
            protocolFailure();
            return;
        default:
            protocolFailure();
        }
    }
}
