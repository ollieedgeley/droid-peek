import QtQuick

QtObject {
    id: root

    property bool sessionReady: false
    property bool panelOpen: false
    property bool settingsOpen: false
    property bool phoneVisible: false
    property bool phoneEnabled: false
    property bool phoneFocused: false
    readonly property bool actionEligible: sessionReady && panelOpen && !settingsOpen
                                                && phoneVisible && phoneEnabled && phoneFocused

    signal keyRequested(string key)
    signal semanticActionRequested(string actionId, string requestId)

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

    function trigger(actionId, requestId) {
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
            if (!validRequestId(requestId))
                return false
            semanticActionRequested(actionId, requestId)
            return true
        case "android-recent-apps":
            keyRequested("app-switch")
            return true
        default:
            return false
        }
    }
}
