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

    Settings {
        id: settings
        visible: false
    }

    SignalSpy {
        id: escapeSpy
        target: scope
        signalName: "escapeRequested"
    }

    SignalSpy {
        id: preferencesSpy
        target: settings
        signalName: "preferencesRequested"
    }

    function init() {
        focusedControl.consumeEscape = false
        escapeSpy.clear()
        preferencesSpy.clear()
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

    function test_android_mode_shortcuts_default_on() {
        compare(settings.androidModeShortcuts, true)
    }

    function test_preferences_request_has_schema_v1_shape() {
        settings.request(
                    true, 125, "medium",
                    ["home", "back", "recent-apps"], false)

        compare(preferencesSpy.count, 1)
        compare(preferencesSpy.signalArguments[0].length, 5)
        compare(preferencesSpy.signalArguments[0][0], true)
        compare(preferencesSpy.signalArguments[0][1], 125)
        compare(preferencesSpy.signalArguments[0][2], "medium")
        compare(preferencesSpy.signalArguments[0][3],
                ["home", "back", "recent-apps"])
        compare(preferencesSpy.signalArguments[0][4], false)
    }

    function test_command_passthrough_setting_is_completely_removed() {
        compare(settings.commandPassthrough, undefined)
        compare(findChild(settings, "commandPassthroughControl"), null)
    }
}
