import QtQuick

QtObject {
    id: root

    property bool semanticIntegrationEnabled: false
    property bool sessionReady: false
    property bool panelOpen: false
    property bool settingsOpen: false
    property bool phoneVisible: false
    property bool phoneEnabled: false
    property bool phoneFocused: false
    readonly property bool actionEligible: semanticIntegrationEnabled
                                                && sessionReady && panelOpen && !settingsOpen
                                                && phoneVisible && phoneEnabled && phoneFocused

    signal keyRequested(string key)
    signal semanticActionRequested(string actionId, string requestId, real expiresAtUnixMs)

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

    function trigger(actionId, requestId, expiresAtUnixMs) {
        if (!actionEligible)
            return false
        switch (actionId) {
        case "android-back":
            keyRequested("back")
            return true
        case "android-home":
            keyRequested("home")
            return true
        case "omarchy-close-current-window":
        case "omarchy-browser":
            if (!validRequestId(requestId)
                    || !validDeadline(expiresAtUnixMs))
                return false
            semanticActionRequested(actionId, requestId, expiresAtUnixMs)
            return true
        case "android-recent-apps":
            keyRequested("app-switch")
            return true
        default:
            return false
        }
    }
}
