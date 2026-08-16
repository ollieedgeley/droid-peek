import QtQuick
import QtTest

TestCase {
    name: "PanelState"

    function test_knownStates_areStable() {
        var knownStates = ["unpaired", "qr-waiting", "pairing", "ready", "disconnected", "unauthorized", "dependency-unavailable"]
        compare(knownStates.indexOf("ready") >= 0, true)
        compare(knownStates.indexOf("failed"), -1)
    }
}
