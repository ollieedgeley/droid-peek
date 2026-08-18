import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "SubmapController"

    property var calls: []

    SubmapController {
        id: controller
    }

    Connections {
        target: controller

        function onSubmapCommandRequested(submap) {
            calls.push("submap:" + submap)
        }

        function onPanelCloseRequested() {
            calls.push("close")
        }
    }

    function init() {
        controller.reset()
        calls = []
        controller.applicationState = "closed"
        controller.androidModeShortcuts = true
        calls = []
    }

    function test_phone_mode_is_exactly_interactive_and_android_mode_enabled() {
        controller.applicationState = "interactive"
        compare(calls, ["submap:omarchy-android"])

        calls = []
        controller.androidModeShortcuts = false
        compare(calls, ["submap:reset"])
    }

    function test_every_noninteractive_state_selects_desktop_map_data() {
        return [
            { tag: "closed", state: "closed" },
            { tag: "setup", state: "setup" },
            { tag: "recovering", state: "recovering" },
            { tag: "management", state: "management" }
        ]
    }

    function test_every_noninteractive_state_selects_desktop_map(data) {
        controller.applicationState = "interactive"
        calls = []

        controller.applicationState = data.state

        compare(calls, ["submap:reset"])
    }

    function test_repeating_the_same_desired_state_does_not_redispatch() {
        controller.applicationState = "interactive"
        compare(calls, ["submap:omarchy-android"])

        controller.applicationState = "interactive"
        controller.androidModeShortcuts = true
        compare(calls, ["submap:omarchy-android"])
    }

    function test_phone_mode_close_resets_synchronously_before_requesting_close() {
        controller.applicationState = "interactive"
        calls = []

        controller.closePanel()

        compare(calls, ["submap:reset", "close"])
    }

    function test_ordinary_close_repeats_the_reset_idempotently() {
        controller.applicationState = "interactive"
        controller.closePanel()
        calls = []

        controller.applicationState = "closed"

        compare(calls, ["submap:reset"])
    }

    function test_helper_restart_and_dispatch_failure_fail_closed() {
        controller.applicationState = "interactive"
        calls = []

        controller.helperRestarted()
        compare(calls, ["submap:reset"])

        calls = []
        controller.applicationState = "interactive"
        calls = []
        controller.dispatchFailed()
        compare(calls, ["submap:reset"])
    }
}
