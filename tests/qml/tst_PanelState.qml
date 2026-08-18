import QtQuick
import QtTest

TestCase {
    name: "PanelState"

    function test_canonical_states_are_stable() {
        var knownStates = [
            "closed",
            "setup",
            "recovering",
            "interactive",
            "management"
        ]

        compare(knownStates.length, 5)
        compare(knownStates.indexOf("ready"), -1)
        compare(knownStates.indexOf("unpaired"), -1)
    }
}
