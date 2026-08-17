import QtQuick

QtObject {
    id: root

    property bool semanticIntegrationEnabled: false
    property bool commandPassthrough: false
    property bool sessionReady: false
    property bool panelOpen: false
    property bool settingsOpen: false
    property bool phoneVisible: false
    property bool phoneEnabled: false
    property bool phoneFocused: false
    readonly property bool phoneInteractionEligible: sessionReady && panelOpen && !settingsOpen
                                                       && phoneVisible && phoneEnabled && phoneFocused
    readonly property bool actionEligible: semanticIntegrationEnabled
                                                && phoneInteractionEligible
    readonly property bool shortcutInhibitionRequested: semanticIntegrationEnabled
                                                           && !commandPassthrough
                                                           && phoneInteractionEligible

    signal keyRequested(string key)
    signal semanticActionRequested(string actionId, string requestId, real expiresAtUnixMs, string actionArgument)

    function quickActionKey(actionId) {
        switch (actionId) {
        case "back": return "back"
        case "home": return "home"
        case "recent-apps": return "app-switch"
        default: return ""
        }
    }

    function validRequestId(requestId) {
        return typeof requestId === "string"
                && /^[A-Za-z0-9-]{1,64}$/.test(requestId)
    }

    function validDeadline(expiresAtUnixMs) {
        return typeof expiresAtUnixMs === "number"
                && isFinite(expiresAtUnixMs)
                && expiresAtUnixMs > 0
                && Math.floor(expiresAtUnixMs) === expiresAtUnixMs
                && expiresAtUnixMs > Date.now()
    }

    function validPackage(packageName) {
        return typeof packageName === "string"
                && packageName.length > 0 && packageName.length <= 255
                && /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(packageName)
    }

    function validSemanticAction(actionId, actionArgument) {
        switch (actionId) {
        case "omarchy-browser":
        case "omarchy-close-current-window":
        case "omarchy-menu":
        case "android-back":
        case "android-home":
        case "android-recent-apps":
            return actionArgument === ""
        case "android-launch-app":
            return validPackage(actionArgument)
        default:
            return false
        }
    }

    function trigger(actionId, requestId, expiresAtUnixMs, actionArgument) {
        actionArgument = actionArgument || ""
        if (!actionEligible
                || !validSemanticAction(actionId, actionArgument)
                || !validRequestId(requestId)
                || !validDeadline(expiresAtUnixMs))
            return false
        semanticActionRequested(actionId, requestId, expiresAtUnixMs, actionArgument)
        return true
    }
}
