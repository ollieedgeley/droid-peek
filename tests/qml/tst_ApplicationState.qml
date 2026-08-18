import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "ApplicationState"

    ApplicationState {
        id: state
    }

    function init() {
        state.reset()
        state.helperEpoch = "17"
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

    function test_five_state_derivation() {
        compare(state.applicationState, "closed")

        state.panelOpen = true
        compare(state.applicationState, "setup")

        state.hasTrustedDevice = true
        compare(state.applicationState, "recovering")

        makeInteractive()
        compare(state.applicationState, "interactive")

        state.managementOpen = true
        compare(state.applicationState, "management")

        state.panelOpen = false
        compare(state.applicationState, "closed")
    }

    function test_management_is_an_overlay_with_absolute_precedence() {
        makeInteractive()
        state.managementOpen = true
        compare(state.applicationState, "management")
        compare(state.availabilityState, "interactive")

        state.captureActive = false
        state.firstValidFrameReceived = false
        compare(state.applicationState, "management")
        compare(state.availabilityState, "recovering")

        state.managementOpen = false
        compare(state.applicationState, "recovering")
    }

    function test_session_started_without_a_usable_preview_stays_recovering() {
        state.panelOpen = true
        state.helperReady = true
        state.hasTrustedDevice = true
        state.sessionGeneration = "4"
        state.sessionStarted = true

        compare(state.applicationState, "recovering")
        compare(state.activity, "starting-preview")
    }

    function test_every_preview_fact_is_required_for_interactive_data() {
        return [
            { tag: "capture unavailable", propertyName: "captureAvailable", value: false },
            { tag: "capture inactive", propertyName: "captureActive", value: false },
            { tag: "no current frame", propertyName: "firstValidFrameReceived", value: false },
            { tag: "zero width", propertyName: "displayWidth", value: 0 },
            { tag: "zero height", propertyName: "displayHeight", value: 0 },
            { tag: "input disabled", propertyName: "previewInputEnabled", value: false },
            { tag: "transport not live", propertyName: "sessionStarted", value: false }
        ]
    }

    function test_every_preview_fact_is_required_for_interactive(data) {
        makeInteractive()
        compare(state.applicationState, "interactive")

        state[data.propertyName] = data.value
        compare(state.applicationState, "recovering")
    }

    function test_preview_fact_loss_recovers_immediately() {
        makeInteractive()
        compare(state.applicationState, "interactive")

        state.firstValidFrameReceived = false
        compare(state.applicationState, "recovering")
    }

    function test_generation_change_clears_transport_and_preview_facts() {
        makeInteractive()
        compare(state.applicationState, "interactive")

        state.sessionGeneration = "2"

        compare(state.applicationState, "recovering")
        compare(state.sessionStarted, false)
        compare(state.captureAvailable, false)
        compare(state.captureActive, false)
        compare(state.firstValidFrameReceived, false)
        compare(state.displayWidth, 0)
        compare(state.displayHeight, 0)
        compare(state.previewInputEnabled, false)
    }

    function test_helper_restart_resets_generation_and_session_facts() {
        makeInteractive()

        state.helperEpoch = "18"

        compare(state.applicationState, "recovering")
        compare(state.sessionGeneration, "0")
        compare(state.sessionStarted, false)
        compare(state.firstValidFrameReceived, false)
    }

    function test_closed_state_wins_over_retained_session_facts() {
        makeInteractive()
        state.panelOpen = false

        compare(state.applicationState, "closed")
        compare(state.sessionStarted, true)
    }
}
