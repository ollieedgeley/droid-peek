import QtQuick

QtObject {
    id: root

    property string applicationState: "closed"
    property string helperEpoch: ""
    property string sessionGeneration: ""
    readonly property int failureCoalesceWindowMs: 2000
    property var failureNotificationTimes: ({})

    signal phoneTargetRequested(var request)
    signal phoneTargetFailureNotificationRequested(string message,
                                                   string coalesceKey)

    function validIdentity(value) {
        return typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value);
    }

    function validRequestId(requestId) {
        return typeof requestId === "string"
                && /^[A-Za-z0-9-]{1,64}$/.test(requestId);
    }

    function validNamedTarget(target) {
        return typeof target === "string"
                && /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/.test(target);
    }

    function validDeadline(expiresAtUnixMs) {
        var now = Date.now();
        return typeof expiresAtUnixMs === "number"
                && isFinite(expiresAtUnixMs)
                && Math.floor(expiresAtUnixMs) === expiresAtUnixMs
                && expiresAtUnixMs > now
                && expiresAtUnixMs <= now + 2000;
    }

    function validPackage(packageName) {
        return typeof packageName === "string"
                && packageName.length > 0 && packageName.length <= 255
                && /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(
                    packageName);
    }

    function validTarget(target) {
        if (typeof target === "string")
            return validNamedTarget(target);
        if (!target || Array.isArray(target)
                || target.type !== "android.app.launch"
                || !validPackage(target.package))
            return false;
        var keys = Object.keys(target);
        return keys.length === 2
                && keys.indexOf("type") >= 0
                && keys.indexOf("package") >= 0;
    }

    function consumePhoneTargetResult(outcome, notificationCode) {
        if (outcome !== "failed")
            return false;
        var message = "";
        switch (notificationCode) {
        case "invalid-target":
            message = "Android shortcut is not supported.";
            break;
        case "target-failed":
            message = "Android shortcut failed.";
            break;
        case "target-timed-out":
            message = "Android shortcut timed out.";
            break;
        case "invalid-deadline":
            message = "Android shortcut expired.";
            break;
        default:
            return false;
        }
        var now = Date.now();
        var previous = failureNotificationTimes[notificationCode];
        if (typeof previous === "number" && now >= previous
                && now - previous < failureCoalesceWindowMs)
            return true;
        failureNotificationTimes[notificationCode] = now;
        phoneTargetFailureNotificationRequested(
                    message,
                    "omarchy-android-phone-target-" + notificationCode);
        return true;
    }

    function acceptPhoneTarget(request) {
        if (applicationState !== "interactive"
                || !validIdentity(helperEpoch)
                || !validIdentity(sessionGeneration)
                || !request || Array.isArray(request)
                || !validRequestId(request.requestId)
                || !validTarget(request.target)
                || !validDeadline(request.expiresAtUnixMs))
            return false;
        var keys = Object.keys(request);
        if (keys.length !== 3
                || keys.indexOf("requestId") < 0
                || keys.indexOf("target") < 0
                || keys.indexOf("expiresAtUnixMs") < 0)
            return false;
        phoneTargetRequested({
            requestId: request.requestId,
            target: request.target,
            expiresAtUnixMs: request.expiresAtUnixMs,
            helperEpoch: helperEpoch,
            sessionGeneration: sessionGeneration
        });
        return true;
    }
}
