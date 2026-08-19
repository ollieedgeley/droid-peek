import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "SubmapController"

    property var calls: []
    property var commands: []
    property var requestIds: []
    SubmapController {
        id: controller
    }

    Connections {
        target: controller

        function onSubmapCommandRequested(command, submap, requestId) {
            commands.push(command)
            calls.push("submap:" + submap)
            requestIds.push(requestId)
        }

        function onPanelCloseRequested() {
            calls.push("close")
        }
    }

    function init() {
        controller.reset()
        calls = []
        controller.androidModeShortcuts = true
        calls = []
        commands = []
        requestIds = []
    }

    function test_allowed_submaps_generate_exact_typed_command_argv_data() {
        return [
            {
                tag: "reset",
                submap: "reset",
                dispatcher: 'hl.dsp.submap("reset")'
            },
            {
                tag: "droid-peek",
                submap: "droid-peek",
                dispatcher: 'hl.dsp.submap("droid-peek")'
            }
        ]
    }

    function test_allowed_submaps_generate_exact_typed_command_argv(data) {
        verify(controller.requestSubmap(data.submap))

        compare(commands.length, 1)
        compare(commands[0].length, 3)
        compare(commands[0][0], "hyprctl")
        compare(commands[0][1], "dispatch")
        compare(commands[0][2], data.dispatcher)
        compare(calls, ["submap:" + data.submap])
    }

    function test_unsupported_submaps_are_rejected_before_command_request() {
        verify(!controller.requestSubmap("unsupported"))

        compare(commands, [])
        compare(calls, [])
    }

    function test_phone_mode_is_exactly_interactive_and_android_mode_enabled() {
        controller.applicationState = "interactive"
        compare(calls, ["submap:droid-peek"])

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
        compare(calls, ["submap:droid-peek"])

        controller.applicationState = "interactive"
        controller.androidModeShortcuts = true
        compare(calls, ["submap:droid-peek"])
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

    function test_request_ids_increase_and_only_latest_is_current() {
        verify(controller.requestSubmap("reset"))
        compare(requestIds.length, 1)
        var firstId = requestIds[0]
        verify(firstId > 0)
        verify(controller.isCurrentRequest(firstId))
        verify(!controller.isCurrentRequest(firstId - 1))

        verify(controller.requestSubmap("droid-peek"))
        compare(requestIds.length, 2)
        var secondId = requestIds[1]
        verify(secondId > firstId)
        verify(!controller.isCurrentRequest(firstId))
        verify(controller.isCurrentRequest(secondId))

        controller.forceReset()
        compare(requestIds.length, 3)
        var thirdId = requestIds[2]
        verify(thirdId > secondId)
        verify(!controller.isCurrentRequest(firstId))
        verify(!controller.isCurrentRequest(secondId))
        verify(controller.isCurrentRequest(thirdId))
        compare(controller.requestGeneration, thirdId)

        var generationBeforeReset = controller.requestGeneration
        controller.reset()
        verify(controller.requestGeneration > generationBeforeReset)
        verify(controller.isCurrentRequest(controller.requestGeneration))
        verify(!controller.isCurrentRequest(thirdId))
    }
}
