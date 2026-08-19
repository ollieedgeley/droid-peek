import QtQuick

QtObject {
    id: root

    property string applicationState: "closed"
    property bool androidModeShortcuts: true
    property string lastDispatchedSubmap: ""
    property int requestGeneration: 0

    readonly property string desiredSubmap: applicationState === "interactive"
                                                    && androidModeShortcuts
                                                ? "omarchy-android"
                                                : "reset"

    signal submapCommandRequested(var command, string submap, int requestId)
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
        requestGeneration += 1;
        submapCommandRequested(command, submap, requestGeneration);
        return true;
    }

    function isCurrentRequest(requestId) {
        return requestId === requestGeneration;
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
