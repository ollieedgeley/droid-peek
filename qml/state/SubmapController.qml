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

    signal submapCommandRequested(var command, string submap)
    signal panelCloseRequested()

    function commandForSubmap(submap) {
        if (submap === "reset")
            return ["hyprctl", "dispatch", 'hl.dsp.submap("reset")'];
        if (submap === "omarchy-android")
            return ["hyprctl", "dispatch",
                    'hl.dsp.submap("omarchy-android")'];
        return null;
    }

    function requestSubmap(submap) {
        var command = commandForSubmap(submap);
        if (command === null)
            return false;
        submapCommandRequested(command, submap);
        return true;
    }

    function dispatchDesiredState() {
        if (desiredSubmap === lastDispatchedSubmap)
            return;
        if (requestSubmap(desiredSubmap))
            lastDispatchedSubmap = desiredSubmap;
    }

    function forceReset() {
        requestSubmap("reset");
        lastDispatchedSubmap = "";
    }

    function reset() {
        lastDispatchedSubmap = "reset";
        applicationState = "closed";
        androidModeShortcuts = true;
        requestSubmap("reset");
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
