import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "SettingsKeyboard"
    when: windowShown
    width: 320
    height: 480

    NestedEscapeScope {
        id: scope
        anchors.fill: parent

        Item {
            id: focusedControl
            anchors.fill: parent
            focus: true
            property bool consumeEscape: false

            Keys.onPressed: function (event) {
                if (consumeEscape && event.key === Qt.Key_Escape)
                    event.accepted = true
            }
        }
    }


    SignalSpy {
        id: escapeSpy
        target: scope
        signalName: "escapeRequested"
    }


    function init() {
        focusedControl.consumeEscape = false
        escapeSpy.clear()
        focusedControl.forceActiveFocus()
        wait(0)
    }

    function test_unhandled_escape_returns_from_settings_scope() {
        keyClick(Qt.Key_Escape)
        compare(escapeSpy.count, 1)
    }

    function test_nested_control_consumes_escape_first() {
        focusedControl.consumeEscape = true
        keyClick(Qt.Key_Escape)
        compare(escapeSpy.count, 0)

        focusedControl.consumeEscape = false
        keyClick(Qt.Key_Escape)
        compare(escapeSpy.count, 1)
    }

    function test_disabled_scope_forwards_escape() {
        scope.escapeEnabled = false
        keyClick(Qt.Key_Escape)
        compare(escapeSpy.count, 0)
        scope.escapeEnabled = true
    }

}
