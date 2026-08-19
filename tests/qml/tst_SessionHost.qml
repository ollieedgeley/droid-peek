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
        var first = SessionRegistry.ensurePanel(panelUrl(), sharedBar,
                                                function (created) {
                                                    seen = created
                                                })
        var second = SessionRegistry.ensurePanel(panelUrl(), sharedBar)
        verify(first !== null)
        compare(first, seen)
        compare(first, second)
        compare(SessionRegistry.panel, first)
    }

    function test_ensurePanel_missing_file_returns_null() {
        var seen = "unset"
        var created = SessionRegistry.ensurePanel(
                    Qt.resolvedUrl("../../missing-panel.qml"), sharedBar,
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
}
