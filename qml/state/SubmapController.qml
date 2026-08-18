import QtQuick

QtObject {
    id: root

    property string applicationState: "closed"
    property bool androidModeShortcuts: true
    property string lastDispatchedSubmap: ""

    readonly property string desiredSubmap: applicationState === "interactive"
                                                    && androidModeShortcuts
                                                ? "omarchy-android"
                                                : "reset"

    signal submapCommandRequested(string submap)
    signal panelCloseRequested()

    function dispatchDesiredState() {
        if (desiredSubmap === lastDispatchedSubmap)
            return;
        lastDispatchedSubmap = desiredSubmap;
        submapCommandRequested(desiredSubmap);
    }

    function forceReset() {
        submapCommandRequested("reset");
        lastDispatchedSubmap = "";
    }

    function reset() {
        lastDispatchedSubmap = "reset";
        applicationState = "closed";
        androidModeShortcuts = true;
        submapCommandRequested("reset");
    }

    function closePanel() {
        forceReset();
        panelCloseRequested();
    }

    function helperRestarted() {
        forceReset();
    }

    function dispatchFailed() {
        forceReset();
    }

    onDesiredSubmapChanged: dispatchDesiredState()
}
