import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "PanelState"

    ApplicationState {
        id: state
    }

    function init() {
        state.reset()
    }

    function makeInteractive() {
        state.panelOpen = true
        state.helperReady = true
        state.hasTrustedDevice = true
        state.sessionGeneration = "1"
        state.sessionStarted = true
        state.captureAvailable = true
        state.captureActive = true
        state.firstValidFrameReceived = true
        state.displayWidth = 1080
        state.displayHeight = 2400
        state.previewInputEnabled = true
    }

    function test_canonical_states_are_stable() {
        var observed = []

        function record() {
            var current = state.applicationState
            if (observed.indexOf(current) === -1)
                observed.push(current)
        }

        compare(state.applicationState, "closed")
        record()

        state.panelOpen = true
        compare(state.applicationState, "setup")
        record()

        state.hasTrustedDevice = true
        compare(state.applicationState, "recovering")
        record()

        makeInteractive()
        compare(state.applicationState, "interactive")
        record()

        state.managementOpen = true
        compare(state.applicationState, "management")
        record()

        compare(observed.length, 5)
        compare(observed.indexOf("ready"), -1)
        compare(observed.indexOf("unpaired"), -1)
    }
}
