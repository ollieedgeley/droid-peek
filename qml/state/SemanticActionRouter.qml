import QtQuick

QtObject {
    id: root

    property bool sessionReady: false
    property bool phoneFocused: false

    signal keyRequested(string key)

    function trigger(actionId) {
        if (!sessionReady || !phoneFocused)
            return false
        switch (actionId) {
        case "android-back":
            keyRequested("back")
            return true
        case "android-home":
            keyRequested("home")
            return true
        case "android-recent-apps":
            keyRequested("app-switch")
            return true
        default:
            return false
        }
    }
}
