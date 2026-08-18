import QtQuick
import QtTest
import "../../qml/PanelLifecycle.js" as PanelLifecycle

TestCase {
    name: "KeepConnected"

    function test_active_session_is_retained_only_when_enabled() {
        compare(PanelLifecycle.closeAction(true, true, true), "retain")
        compare(PanelLifecycle.closeAction(true, true, false), "stop-session")
    }

    function test_pairing_and_idle_helpers_are_never_retained() {
        compare(PanelLifecycle.closeAction(true, false, true), "cancel-pairing")
        compare(PanelLifecycle.closeAction(true, false, false), "cancel-pairing")
        compare(PanelLifecycle.closeAction(false, true, true), "none")
    }
}
