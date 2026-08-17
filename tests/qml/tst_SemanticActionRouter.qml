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

    function init() {
        router.sessionReady = false
        router.phoneFocused = false
        keySpy.clear()
    }

    function test_focused_ready_phone_receives_native_actions() {
        router.sessionReady = true
        router.phoneFocused = true

        verify(router.trigger("android-back"))
        verify(router.trigger("android-home"))
        verify(router.trigger("android-recent-apps"))
        compare(keySpy.count, 3)
        compare(keySpy.signalArguments[0][0], "back")
        compare(keySpy.signalArguments[1][0], "home")
        compare(keySpy.signalArguments[2][0], "app-switch")
    }

    function test_toolbar_action_ids_map_to_protocol_keys() {
        compare(router.quickActionKey("back"), "back")
        compare(router.quickActionKey("home"), "home")
        compare(router.quickActionKey("recent-apps"), "app-switch")
        compare(router.quickActionKey("unknown"), "")
    }

    function test_actions_do_not_steal_unfocused_omarchy_shortcuts() {
        router.sessionReady = true
        verify(!router.trigger("android-back"))
        router.phoneFocused = true
        router.sessionReady = false
        verify(!router.trigger("android-home"))
        verify(!router.trigger("open-universal-search"))
        compare(keySpy.count, 0)
    }
}
