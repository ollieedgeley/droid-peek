import QtQuick

QtObject {
    id: root

    property string applicationState: "closed"
    property string helperEpoch: ""
    property string sessionGeneration: ""
    readonly property int failureCoalesceWindowMs: 2000
    property var failureNotificationTimes: ({})
    property var pendingLabels: ({})

    signal phoneTargetRequested(var request)
    signal phoneTargetFailureNotificationRequested(string message)

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

    function validComponentField(value) {
        return typeof value === "string" && value.length > 0;
    }

    function validKeyName(keyName) {
        if (typeof keyName !== "string")
            return false;
        var match = /^[a-z]+(-[a-z]+)*/.exec(keyName);
        return match !== null && match[0].length === keyName.length;
    }

    function validDescription(description) {
        return typeof description === "string" && description.length > 0;
    }

    function validTarget(target) {
        if (typeof target === "string")
            return validNamedTarget(target);
        if (!target || typeof target !== "object" || Array.isArray(target))
            return false;
        var keys = Object.keys(target);
        if (target.type === "android.component.launch")
            return keys.length === 3 && keys.indexOf("type") >= 0
                    && keys.indexOf("package") >= 0
                    && keys.indexOf("activity") >= 0
                    && validComponentField(target.package)
                    && validComponentField(target.activity);
        if (keys.length !== 2 || keys.indexOf("type") < 0)
            return false;
        if (target.type === "android.app.launch")
            return keys.indexOf("package") >= 0
                    && validPackage(target.package);
        if (target.type === "android.keyevent")
            return keys.indexOf("key") >= 0 && validKeyName(target.key);
        return false;
    }

    function consumePhoneTargetResult(requestId, outcome, notificationCode) {
        var pending = typeof requestId === "string"
                ? pendingLabels[requestId] : undefined;
        if (typeof requestId === "string")
            delete pendingLabels[requestId];
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
        var label = pending && pending.text;
        if (typeof label === "string" && label.length > 0 && pending.openTarget)
            message = "Couldn't open " + label + ".";
        var now = Date.now();
        var previous = failureNotificationTimes[notificationCode];
        if (typeof previous === "number" && now >= previous
                && now - previous < failureCoalesceWindowMs)
            return true;
        failureNotificationTimes[notificationCode] = now;
        phoneTargetFailureNotificationRequested(message);
        return true;
    }

    function acceptPhoneTarget(request) {
        if (applicationState !== "interactive"
                || !validIdentity(helperEpoch)
                || !validIdentity(sessionGeneration)
                || !request || Array.isArray(request)
                || !validRequestId(request.requestId)
                || !validDeadline(request.expiresAtUnixMs))
            return false;
        var keys = Object.keys(request);
        if ((keys.length !== 3 && keys.length !== 4)
                || keys.indexOf("requestId") < 0
                || keys.indexOf("target") < 0
                || keys.indexOf("expiresAtUnixMs") < 0)
            return false;
        if (keys.length === 4
                && (keys.indexOf("description") < 0
                    || !validDescription(request.description)))
            return false;
        if (!validTarget(request.target)) {
            if (request.target && typeof request.target === "object"
                    && !Array.isArray(request.target)
                    && request.target.type === "android.component.launch")
                consumePhoneTargetResult(request.requestId, "failed",
                                         "invalid-target");
            return false;
        }
        if (validDescription(request.description))
            pendingLabels[request.requestId] = {
                text: request.description,
                openTarget: typeof request.target === "object"
                        && (request.target.type === "android.app.launch"
                            || request.target.type === "android.component.launch")
            };
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
