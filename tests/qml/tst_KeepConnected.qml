import QtQuick
import QtTest
import "../../qml/PanelLifecycle.js" as PanelLifecycle

TestCase {
    name: "KeepConnected"

    function test_ready_session_is_retained_only_when_enabled() {
        compare(PanelLifecycle.closeAction(true, "ready", "session-started", true), "retain")
        compare(PanelLifecycle.closeAction(false, "ready", "session-started", true), "stop-session")
    }

    function test_trusted_session_start_can_finish_while_hidden() {
        compare(PanelLifecycle.closeAction(true, "pairing", "connected", true), "retain")
        compare(PanelLifecycle.closeAction(true, "pairing", "session-starting", true), "retain")
    }

    function test_pairing_and_idle_helpers_are_never_retained() {
        compare(PanelLifecycle.closeAction(true, "qr-waiting", "qr-waiting", true), "cancel-pairing")
        compare(PanelLifecycle.closeAction(true, "pairing", "pairing", true), "cancel-pairing")
        compare(PanelLifecycle.closeAction(true, "disconnected", "session-ended", true), "cancel-pairing")
        compare(PanelLifecycle.closeAction(true, "ready", "session-started", false), "none")
    }
}
