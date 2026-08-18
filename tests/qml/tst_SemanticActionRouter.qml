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
        router.semanticIntegrationEnabled = true
        router.commandPassthrough = true
        router.sessionReady = true
        router.panelOpen = true
        router.settingsOpen = false
        router.phoneVisible = true
        router.phoneEnabled = true
        router.phoneFocused = true
        router.phoneInteractionReady = true
    }

    function init() {
        router.semanticIntegrationEnabled = false
        router.sessionReady = false
        router.panelOpen = false
        router.settingsOpen = false
        router.phoneVisible = false
        router.phoneEnabled = false
        router.phoneFocused = false
        router.phoneInteractionReady = false
        router.commandPassthrough = false
        keySpy.clear()
        actionSpy.clear()
    }

    function test_preference_off_refuses_routed_actions_under_valid_focus() {
        makeEligible()
        router.semanticIntegrationEnabled = false
        var deadline = Date.now() + 2000

        compare(router.actionEligible, false)
        verify(!router.trigger(
                   "omarchy-close-current-window", "request-off-close", deadline))
        verify(!router.trigger(
                   "omarchy-browser", "request-off-browser", deadline))
        compare(keySpy.count, 0)
        compare(actionSpy.count, 0)
        compare(router.quickActionKey("back"), "back")
        compare(router.quickActionKey("home"), "home")
        compare(router.quickActionKey("recent-apps"), "app-switch")
    }

    function test_passthrough_only_controls_compositor_shortcut_inhibition() {
        makeEligible()
        router.commandPassthrough = false
        var deadline = Date.now() + 2000

        compare(router.shortcutInhibitionRequested, true)
        compare(router.actionEligible, true)
        verify(router.trigger(
                   "omarchy-browser", "request-inhibited-browser", deadline))
        compare(actionSpy.count, 1)

        router.commandPassthrough = true
        compare(router.shortcutInhibitionRequested, false)
        compare(router.actionEligible, true)
    }

    function test_disabling_preference_applies_before_the_next_trigger() {
        makeEligible()
        var deadline = Date.now() + 2000
        verify(router.trigger(
                   "omarchy-close-current-window", "request-enabled", deadline))
        compare(actionSpy.count, 1)

        router.semanticIntegrationEnabled = false

        compare(router.actionEligible, false)
        verify(!router.trigger(
                   "omarchy-browser", "request-disabled", deadline))
        compare(actionSpy.count, 1)
        compare(keySpy.count, 0)
        compare(router.quickActionKey("back"), "back")
    }

    function test_focused_ready_phone_receives_native_actions() {
        makeEligible()
        var deadline = Date.now() + 2000

        verify(router.trigger("android-back", "request-back", deadline))
        verify(router.trigger("android-home", "request-home", deadline))
        verify(router.trigger("android-recent-apps", "request-recent", deadline))
        compare(keySpy.count, 0)
        compare(actionSpy.count, 3)
        compare(actionSpy.signalArguments[0][0], "android-back")
        compare(actionSpy.signalArguments[1][0], "android-home")
        compare(actionSpy.signalArguments[2][0], "android-recent-apps")
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
            { tag: "preview has no current frame", propertyName: "phoneInteractionReady", value: false },
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

    function test_catalogued_and_parameterized_actions_are_validated() {
        makeEligible()
        var deadline = Date.now() + 2000

        verify(router.trigger("omarchy-menu", "request-3", deadline))
        verify(router.trigger(
                   "android-launch-app", "request-package", deadline,
                   "com.example.notes"))
        verify(!router.trigger(
                   "android-launch-app", "request-bad-package", deadline,
                   "bad package"))
        verify(!router.trigger("open-universal-search", "request-4", deadline))
        verify(!router.trigger("unknown-action", "request-5", deadline))
        verify(!router.trigger("omarchy-browser", "", deadline))
        verify(!router.trigger("omarchy-browser", "../unsafe", deadline))
        compare(keySpy.count, 0)
        compare(actionSpy.count, 2)
        compare(actionSpy.signalArguments[1][3], "com.example.notes")
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
