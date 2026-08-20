import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase

    name: "Settings"
    when: windowShown
    visible: true
    width: 400
    height: 640

    Settings {
        id: settings

        width: testCase.width
        height: testCase.height
    }

    SignalSpy {
        id: preferencesSpy

        target: settings
        signalName: "preferencesRequested"
    }

    function findObject(propertyName, value, markerProperty) {
        var seen = [];
        var pending = [settings];
        while (pending.length > 0) {
            var object = pending.pop();
            if (!object || seen.indexOf(object) !== -1)
                continue;
            seen.push(object);
            if (object[propertyName] === value
                    && (!markerProperty
                        || object[markerProperty] !== undefined))
                return object;
            if (object.contentItem)
                pending.push(object.contentItem);
            var data = object.data;
            if (data !== undefined) {
                for (var dataIndex = 0; dataIndex < data.length; ++dataIndex)
                    pending.push(data[dataIndex]);
            }
            var children = object.children;
            if (children !== undefined) {
                for (var childIndex = 0; childIndex < children.length;
                     ++childIndex)
                    pending.push(children[childIndex]);
            }
        }
        return null;
    }

    function currentPreferences() {
        return {
            keepConnected: settings.keepConnected,
            previewScale: settings.previewScale,
            videoQuality: settings.videoQuality,
            quickActions: settings.quickActions.slice(),
            androidModeShortcuts: settings.androidModeShortcuts
        };
    }

    function preferencesAt(index) {
        var arguments_ = preferencesSpy.signalArguments[index];
        return {
            keepConnected: arguments_[0],
            previewScale: arguments_[1],
            videoQuality: arguments_[2],
            quickActions: arguments_[3],
            androidModeShortcuts: arguments_[4]
        };
    }

    function verifyPreferences(index, expected) {
        var actual = preferencesAt(index);
        compare(actual.keepConnected, expected.keepConnected);
        compare(actual.previewScale, expected.previewScale);
        compare(actual.videoQuality, expected.videoQuality);
        compare(actual.quickActions, expected.quickActions);
        compare(actual.androidModeShortcuts, expected.androidModeShortcuts);
        verify(actual.quickActions !== settings.quickActions,
               "preferencesRequested must copy quickActions");
    }

    function init() {
        settings.keepConnected = false;
        settings.previewScale = 100;
        settings.videoQuality = "high";
        settings.quickActions = ["back", "home", "recent-apps"];
        settings.androidModeShortcuts = true;
        preferencesSpy.clear();
    }

    function test_keep_connected_preserves_other_preferences() {
        var control = findObject("objectName", "keepConnectedControl");
        verify(control !== null);
        compare(control.label, "Keep device connected");

        var expected = currentPreferences();
        expected.keepConnected = true;
        control.clicked();
        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);

        settings.keepConnected = true;
        preferencesSpy.clear();
        expected = currentPreferences();
        expected.keepConnected = false;
        control.clicked();
        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);
    }

    function test_android_mode_shortcuts_preserve_other_preferences() {
        var control = findObject("objectName",
                                 "androidModeShortcutsControl");
        verify(control !== null);

        var expected = currentPreferences();
        expected.androidModeShortcuts = false;
        control.clicked();
        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);

        settings.androidModeShortcuts = false;
        preferencesSpy.clear();
        expected = currentPreferences();
        expected.androidModeShortcuts = true;
        control.clicked();
        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);
    }

    function test_preview_scale_rounding_and_bounds_data() {
        return [
            { tag: "below-minimum", input: 1, expected: 50 },
            { tag: "minimum", input: 50, expected: 50 },
            { tag: "round-down", input: 52, expected: 50 },
            { tag: "round-up", input: 53, expected: 55 },
            { tag: "upper-round-down", input: 147, expected: 145 },
            { tag: "upper-round-up", input: 148, expected: 150 },
            { tag: "maximum", input: 150, expected: 150 },
            { tag: "above-maximum", input: 999, expected: 150 }
        ];
    }

    function test_preview_scale_rounding_and_bounds(data) {
        var expected = currentPreferences();
        expected.previewScale = data.expected;

        settings.setPreviewScale(data.input);

        compare(preferencesSpy.count, 1);
        compare(data.expected % 5, 0);
        verifyPreferences(0, expected);
    }

    function test_preview_scale_does_not_emit_when_rounded_value_is_unchanged() {
        settings.setPreviewScale(102);
        compare(preferencesSpy.count, 0);
    }

    function test_preview_scale_control_uses_five_point_steps_and_bounds() {
        var control = findObject("objectName", "previewScaleControl");
        verify(control !== null);
        control.forceActiveFocus();
        compare(control.activeFocus, true);

        var expected = currentPreferences();
        expected.previewScale = 105;
        keyClick(Qt.Key_Right);
        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);

        settings.previewScale = 105;
        preferencesSpy.clear();
        expected = currentPreferences();
        expected.previewScale = 100;
        keyClick(Qt.Key_Left);
        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);

        settings.previewScale = 100;
        preferencesSpy.clear();
        expected = currentPreferences();
        expected.previewScale = 50;
        keyClick(Qt.Key_Home);
        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);

        settings.previewScale = 50;
        preferencesSpy.clear();
        expected = currentPreferences();
        expected.previewScale = 150;
        keyClick(Qt.Key_End);
        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);
    }

    function test_video_quality_preserves_other_preferences_data() {
        return [
            { tag: "low", label: "Low", expected: "low" },
            { tag: "medium", label: "Medium", expected: "medium" },
            { tag: "high", label: "High", expected: "high" }
        ];
    }

    function test_video_quality_preserves_other_preferences(data) {
        var button = findObject("text", data.label, "selected");
        verify(button !== null);
        var expected = currentPreferences();
        expected.videoQuality = data.expected;

        button.clicked();

        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);
    }

    function test_quick_action_replacement_data() {
        return [
            {
                tag: "first-slot",
                label: "Slot 1",
                replacement: "recent-apps",
                expected: ["recent-apps", "home", "recent-apps"]
            },
            {
                tag: "middle-slot",
                label: "Slot 2",
                replacement: "back",
                expected: ["back", "back", "recent-apps"]
            },
            {
                tag: "last-slot",
                label: "Slot 3",
                replacement: "home",
                expected: ["back", "home", "home"]
            }
        ];
    }

    function test_quick_action_replacement(data) {
        var dropdown = findObject("label", data.label, "changed");
        verify(dropdown !== null);
        var originalActions = settings.quickActions;
        var expected = currentPreferences();
        expected.quickActions = data.expected;

        dropdown.changed(data.replacement);

        compare(preferencesSpy.count, 1);
        verifyPreferences(0, expected);
        compare(settings.quickActions, ["back", "home", "recent-apps"]);
        verify(settings.quickActions === originalActions,
               "Replacing a slot must not mutate the source preferences");
    }
}
