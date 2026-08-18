import QtQuick
import QtTest
import qs.Commons
import "../../qml/components"

TestCase {
    id: testCase
    name: "PhoneToolbar"
    when: windowShown
    width: 420
    visible: true
    height: 120

    QtObject {
        id: mockBar
        property bool vertical: false
        property bool transparent: false
        property color background: "#28323c"
        property color barForeground: "#e3e8ee"
        property color urgent: "#cc3344"
        property string fontFamily: "monospace"
        property bool foregroundAnimationEnabled: false
        property int transparencyToggleCount: 0

        function showTooltip(target, text) {}
        function hideTooltip(target) {}
        function registerClickTarget(target) {}
        function unregisterClickTarget(target) {}
        function toggleTransparency() {
            transparencyToggleCount += 1
            transparent = !transparent
        }
    }

    PhoneToolbar {
        id: toolbar
        width: testCase.width
        height: implicitHeight
        bar: mockBar
        applicationState: "interactive"
    }

    SignalSpy {
        id: actionSpy
        target: toolbar
        signalName: "actionRequested"
    }

    SignalSpy {
        id: settingsSpy
        target: toolbar
        signalName: "settingsRequested"
    }

    SignalSpy {
        id: keepConnectedSpy
        target: toolbar
        signalName: "keepConnectedRequested"
    }

    SignalSpy {
        id: backSpy
        target: toolbar
        signalName: "backRequested"
    }

    function objectNamed(name) {
        var seen = []
        var pending = [toolbar]
        while (pending.length > 0) {
            var object = pending.pop()
            if (!object || seen.indexOf(object) !== -1)
                continue
            seen.push(object)
            if (object.objectName === name)
                return object

            var data = object.data
            if (data !== undefined) {
                for (var dataIndex = 0; dataIndex < data.length; ++dataIndex)
                    pending.push(data[dataIndex])
            }
            var children = object.children
            if (children !== undefined) {
                for (var childIndex = 0; childIndex < children.length; ++childIndex)
                    pending.push(children[childIndex])
            }
        }
        return null
    }

    function button(name) {
        var item = objectNamed(name)
        verify(item !== null, "Missing toolbar control " + name)
        return item
    }

    function init() {
        toolbar.actions = ["back", "home", "recent-apps"]
        toolbar.keepConnected = false
        toolbar.settingsOpen = false
        toolbar.applicationState = "interactive"
        mockBar.vertical = false
        mockBar.transparent = false
        mockBar.transparencyToggleCount = 0
        actionSpy.clear()
        settingsSpy.clear()
        keepConnectedSpy.clear()
        backSpy.clear()
        wait(0)
    }

    function test_bar_is_forwarded_and_horizontal_metrics_ignore_bar_orientation() {
        var names = ["quickActionButton-back", "quickActionButton-home",
                     "quickActionButton-recent-apps", "keepConnectedButton",
                     "settingsButton"]
        for (var index = 0; index < names.length; ++index) {
            var control = button(names[index])
            compare(control.bar, mockBar)
            compare(control.fixedWidth, Style.bar.iconSlot)
            compare(control.fixedHeight, Style.bar.sizeHorizontal)
            compare(control.implicitWidth, Style.bar.iconSlot)
            compare(control.implicitHeight, Style.bar.sizeHorizontal)
        }
        compare(toolbar.implicitHeight, Style.bar.sizeHorizontal)

        mockBar.vertical = true
        wait(0)
        for (var verticalIndex = 0; verticalIndex < names.length; ++verticalIndex) {
            var verticalControl = button(names[verticalIndex])
            compare(verticalControl.implicitWidth, Style.bar.iconSlot)
            compare(verticalControl.implicitHeight, Style.bar.sizeHorizontal)
        }
        compare(toolbar.implicitHeight, Style.bar.sizeHorizontal)
    }

    function test_surface_tracks_live_bar_background_and_transparency() {
        var surface = button("toolbarSurface")
        compare(surface.color, mockBar.background)

        mockBar.transparent = true
        wait(0)
        compare(surface.color.a, 0)
    }

    function test_disabled_actions_are_not_pointer_or_keyboard_activatable() {
        toolbar.applicationState = "starting"
        var action = button("quickActionButton-home")
        compare(toolbar.controlsEnabled, false)
        compare(action.interactive, false)

        mouseClick(action, action.width / 2, action.height / 2, Qt.LeftButton)
        action.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(actionSpy.count, 0)
    }

    function test_actions_keep_pointer_and_keyboard_signal_contracts() {
        var backAction = button("quickActionButton-back")
        mouseClick(backAction, backAction.width / 2, backAction.height / 2,
                   Qt.LeftButton)
        compare(actionSpy.count, 1)
        compare(actionSpy.signalArguments[0][0], "back")

        var homeAction = button("quickActionButton-home")
        homeAction.forceActiveFocus()
        keyClick(Qt.Key_Space)
        compare(actionSpy.count, 2)
        compare(actionSpy.signalArguments[1][0], "home")
    }

    function test_keep_connected_is_visible_dimmed_off_and_uses_normal_foreground_on() {
        var keep = button("keepConnectedButton")
        compare(keep.visible, true)
        compare(keep.dimmed, true)
        compare(keep.useActiveColor, false)
        compare(keep.foreground, mockBar.barForeground)
        verify(keep.opacity < 1)
        verify(keep.tooltipText.indexOf("off") !== -1)

        mouseClick(keep, keep.width / 2, keep.height / 2, Qt.LeftButton)
        compare(keepConnectedSpy.count, 1)
        compare(keepConnectedSpy.signalArguments[0][0], true)

        toolbar.keepConnected = true
        compare(keep.dimmed, false)
        tryCompare(keep, "opacity", 1)
        compare(keep.foreground, mockBar.barForeground)
        verify(keep.tooltipText.indexOf("on") !== -1)
    }

    function test_settings_and_management_back_keep_signals_and_keyboard_focus() {
        var settings = button("settingsButton")
        settings.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(settingsSpy.count, 1)
        verify(settings.tooltipText.length > 0)

        toolbar.settingsOpen = true
        wait(0)
        var managementBack = button("settingsBackButton")
        compare(managementBack.iconText, "\uf053")
        toolbar.forceSettingsFocus()
        compare(managementBack.activeFocus, true)
        keyClick(Qt.Key_Return)
        compare(backSpy.count, 1)
    }

    function test_unused_surface_double_click_toggles_transparency_but_buttons_do_not() {
        var surface = button("toolbarSurface")
        mouseDoubleClickSequence(surface, toolbar.width / 2,
                                 surface.height / 2, Qt.LeftButton)
        compare(mockBar.transparencyToggleCount, 1)

        mockBar.transparencyToggleCount = 0
        var action = button("quickActionButton-home")
        mouseDoubleClickSequence(action, action.width / 2,
                                 action.height / 2, Qt.LeftButton)
        compare(mockBar.transparencyToggleCount, 0)
        compare(actionSpy.count, 1)
    }
}
