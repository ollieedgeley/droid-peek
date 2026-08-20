import QtQuick
import QtTest
import "../../qml/session/SessionRegistry.js" as SessionRegistry

TestCase {
    id: testCase
    name: "SessionHost"
    when: windowShown
    visible: true
    width: 720
    height: 450

    Item {
        id: sharedBar
        width: 720
        height: 26
        property string position: "top"
        property real barSize: 26
        property bool vertical: false
        property color barForeground: "#f0f0f0"
        property color foreground: barForeground
        property color background: "#202020"
        property color urgent: "#ff5555"
        property bool transparent: false
        property string fontFamily: "monospace"
        property bool foregroundAnimationEnabled: false

        function showTooltip(item, text, position) {}
        function hideTooltip() {}
        function registerClickTarget(item) {}
        function unregisterClickTarget(item) {}
    }

    Loader {
        id: widgetA
        active: false
        source: Qt.resolvedUrl("../../BarWidget.qml")
        onLoaded: item.bar = sharedBar
    }

    Loader {
        id: widgetB
        active: false
        source: Qt.resolvedUrl("../../BarWidget.qml")
        onLoaded: item.bar = sharedBar
    }

    function panelUrl() {
        return Qt.resolvedUrl("../../Panel.qml")
    }

    function loadWidgets() {
        widgetA.active = true
        widgetB.active = true
        tryCompare(widgetA, "status", Loader.Ready)
        tryCompare(widgetB, "status", Loader.Ready)
        verify(widgetA.item !== null)
        verify(widgetB.item !== null)
        tryVerify(function () {
            return widgetA.item.panel !== null && widgetB.item.panel !== null
        })
    }

    function init() {
        SessionRegistry.resetForTests()
    }

    function cleanup() {
        widgetA.active = false
        widgetB.active = false
        SessionRegistry.resetForTests()
    }

    function test_ensurePanel_returns_identical_instance() {
        var seen = null
        var first = SessionRegistry.ensurePanel(panelUrl(),
                                                function (created) {
                                                    seen = created
                                                })
        var second = SessionRegistry.ensurePanel(panelUrl())
        verify(first !== null)
        compare(first, seen)
        compare(first, second)
        compare(SessionRegistry.panel, first)
    }

    function test_ensurePanel_missing_file_returns_null() {
        var seen = "unset"
        var created = SessionRegistry.ensurePanel(
                    Qt.resolvedUrl("../../missing-panel.qml"),
                    function (panel) {
                        seen = panel
                    })
        compare(created, null)
        compare(SessionRegistry.panel, null)
        compare(seen, "unset")
    }

    function test_second_owner_rebinds_without_second_helper() {
        loadWidgets()
        compare(widgetA.item.panel, widgetB.item.panel)
        compare(SessionRegistry.panel, widgetA.item.panel)

        widgetA.item.open()
        compare(widgetA.item.opened, true)
        compare(widgetB.item.opened, false)
        compare(widgetA.item.panel.hostWidget, widgetA.item)
        tryVerify(function () {
            return widgetA.item.panel.acceptedHelperEpoch !== ""
        })
        var epoch = widgetA.item.panel.acceptedHelperEpoch

        widgetB.item.open()
        compare(widgetA.item.panel, widgetB.item.panel)
        compare(widgetB.item.panel.hostWidget, widgetB.item)
        compare(widgetB.item.opened, true)
        compare(widgetA.item.opened, false)
        compare(widgetB.item.panel.acceptedHelperEpoch, epoch)
        compare(widgetB.item.panel.opened, true)
    }

    function objectNamedFrom(rootObject, name) {
        var seen = []
        var pending = [rootObject]
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
                for (var childIndex = 0; childIndex < children.length;
                     ++childIndex)
                    pending.push(children[childIndex])
            }
        }
        return null
    }

    function findHelperProcess(panel) {
        var seen = []
        var pending = [panel]
        while (pending.length > 0) {
            var object = pending.pop()
            if (!object || seen.indexOf(object) !== -1)
                continue
            seen.push(object)
            if (object.stdinEnabled === true)
                return object
            var data = object.data
            if (data !== undefined) {
                for (var dataIndex = 0; dataIndex < data.length; ++dataIndex)
                    pending.push(data[dataIndex])
            }
            var children = object.children
            if (children !== undefined) {
                for (var childIndex = 0; childIndex < children.length;
                     ++childIndex)
                    pending.push(children[childIndex])
            }
        }
        return null
    }
    function countPhoneIpc(object) {
        var count = 0
        var seen = []
        var pending = [object]
        while (pending.length > 0) {
            var child = pending.pop()
            if (!child || seen.indexOf(child) !== -1)
                continue
            seen.push(child)
            if (child.target === "ollieedgeley.droidpeek")
                count += 1
            var data = child.data
            if (data !== undefined) {
                for (var dataIndex = 0; dataIndex < data.length; ++dataIndex)
                    pending.push(data[dataIndex])
            }
            var children = child.children
            if (children !== undefined) {
                for (var childIndex = 0; childIndex < children.length;
                     ++childIndex)
                    pending.push(children[childIndex])
            }
        }
        return count
    }

    function test_bind_does_not_steal_open_panel_host() {
        loadWidgets()
        widgetA.item.open()
        compare(widgetA.item.opened, true)
        verify(widgetA.item.panel.hostWidget === widgetA.item)

        widgetB.item.bindSharedPanel()
        verify(widgetA.item.panel.hostWidget === widgetA.item)
        compare(widgetA.item.opened, true)
        compare(widgetB.item.opened, false)
    }

    function test_nonlast_host_destroy_keeps_retained_helper() {
        loadWidgets()
        widgetA.item.open()
        tryVerify(function () {
            return widgetA.item.panel.acceptedHelperEpoch !== ""
        })
        var panel = widgetA.item.panel
        var helper = findHelperProcess(panel)
        verify(helper !== null)
        compare(helper.running, true)

        widgetB.active = false
        compare(SessionRegistry.panel, panel)
        compare(panel.hostWidget, widgetA.item)
        compare(helper.running, true)
    }

    function test_last_host_teardown_destroys_panel_and_stops_helper() {
        loadWidgets()
        widgetA.item.open()
        tryVerify(function () {
            return widgetA.item.panel.acceptedHelperEpoch !== ""
        })
        var panel = widgetA.item.panel
        var helper = findHelperProcess(panel)
        verify(helper !== null)
        compare(helper.running, true)

        widgetA.active = false
        widgetB.active = false
        compare(SessionRegistry.panel, null)
    }

    function test_phone_ipc_is_registered_once_on_shared_panel() {
        loadWidgets()
        var panel = widgetA.item.panel
        compare(countPhoneIpc(widgetA.item), 0)
        compare(countPhoneIpc(widgetB.item), 0)
        compare(countPhoneIpc(panel), 1)
        verify(typeof panel.phoneTarget === "function")
        verify(typeof panel.configureScrcpy === "function")
        compare(typeof widgetA.item.routedWidget, "undefined")
    }
}
