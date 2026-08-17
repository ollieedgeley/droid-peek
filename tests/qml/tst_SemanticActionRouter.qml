import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "SemanticActionRouter"

    SemanticActionRouter {
        id: router
    }

    SignalSpy {
        id: keySpy
        target: router
        signalName: "keyRequested"
    }

    SignalSpy {
        id: actionSpy
        target: router
        signalName: "semanticActionRequested"
    }

    function makeEligible() {
        router.sessionReady = true
        router.panelOpen = true
        router.settingsOpen = false
        router.phoneVisible = true
        router.phoneEnabled = true
        router.phoneFocused = true
    }

    function init() {
        router.sessionReady = false
        router.panelOpen = false
        router.settingsOpen = false
        router.phoneVisible = false
        router.phoneEnabled = false
        router.phoneFocused = false
        keySpy.clear()
        actionSpy.clear()
    }

    function test_focused_ready_phone_receives_native_actions() {
        makeEligible()

        verify(router.trigger("android-back"))
        verify(router.trigger("android-home"))
        verify(router.trigger("android-recent-apps"))
        compare(keySpy.count, 3)
        compare(keySpy.signalArguments[0][0], "back")
        compare(keySpy.signalArguments[1][0], "home")
        compare(keySpy.signalArguments[2][0], "app-switch")
    }

    function test_focused_ready_phone_receives_correlated_omarchy_actions() {
        makeEligible()
        var closeDeadline = Date.now() + 2000

        verify(router.trigger(
                   "omarchy-close-current-window", "request-1", closeDeadline))
        compare(actionSpy.count, 1)
        compare(actionSpy.signalArguments[0][0], "omarchy-close-current-window")
        compare(actionSpy.signalArguments[0][1], "request-1")
        compare(actionSpy.signalArguments[0][2], closeDeadline)

        var browserDeadline = Date.now() + 2000
        verify(router.trigger(
                   "omarchy-browser", "request-2", browserDeadline))
        compare(actionSpy.count, 2)
        compare(actionSpy.signalArguments[1][0], "omarchy-browser")
        compare(actionSpy.signalArguments[1][1], "request-2")
        compare(actionSpy.signalArguments[1][2], browserDeadline)
    }

    function test_focus_boundaries_data() {
        return [
            { tag: "session lost", propertyName: "sessionReady", value: false },
            { tag: "panel closed", propertyName: "panelOpen", value: false },
            { tag: "settings open", propertyName: "settingsOpen", value: true },
            { tag: "preview hidden", propertyName: "phoneVisible", value: false },
            { tag: "preview disabled", propertyName: "phoneEnabled", value: false },
            { tag: "preview unfocused", propertyName: "phoneFocused", value: false }
        ]
    }

    function test_focus_boundaries(data) {
        makeEligible()
        router[data.propertyName] = data.value

        verify(!router.trigger(
                   "omarchy-browser", "request-boundary", Date.now() + 2000))
        compare(actionSpy.count, 0)
    }

    function test_unavailable_unknown_and_uncorrelated_actions_remain_unhandled() {
        makeEligible()
        var deadline = Date.now() + 2000

        verify(!router.trigger("omarchy-menu", "request-3", deadline))
        verify(!router.trigger("open-universal-search", "request-4", deadline))
        verify(!router.trigger("unknown-action", "request-5", deadline))
        verify(!router.trigger("omarchy-browser", "", deadline))
        verify(!router.trigger("omarchy-browser", "../unsafe", deadline))
        compare(keySpy.count, 0)
        compare(actionSpy.count, 0)
    }

    function test_semantic_actions_require_valid_future_integer_deadlines() {
        makeEligible()

        verify(!router.trigger("omarchy-browser", "request-missing"))
        verify(!router.trigger(
                   "omarchy-browser", "request-string", String(Date.now() + 2000)))
        verify(!router.trigger(
                   "omarchy-browser", "request-fraction", Date.now() + 2000.5))
        verify(!router.trigger(
                   "omarchy-browser", "request-expired", Date.now() - 1))
        verify(!router.trigger(
                   "omarchy-browser", "request-invalid", NaN))
        compare(keySpy.count, 0)
        compare(actionSpy.count, 0)
    }

    function test_toolbar_action_ids_map_to_protocol_keys() {
        compare(router.quickActionKey("back"), "back")
        compare(router.quickActionKey("home"), "home")
        compare(router.quickActionKey("recent-apps"), "app-switch")
        compare(router.quickActionKey("unknown"), "")
    }
}
