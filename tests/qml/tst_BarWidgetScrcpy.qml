import QtQuick
import QtTest
import "../../qml/session/SessionRegistry.js" as SessionRegistry

TestCase {
    id: testCase
    name: "BarWidgetScrcpy"
    when: windowShown
    visible: true
    width: 720
    height: 80

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
        id: widget
        active: false
        source: Qt.resolvedUrl("../../BarWidget.qml")
        onLoaded: item.bar = sharedBar
    }

    function encodeEnvelope(value) {
        var json = JSON.stringify(value)
        var binary = unescape(encodeURIComponent(json))
        return Qt.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "")
    }

    function loadWidget() {
        widget.active = true
        tryCompare(widget, "status", Loader.Ready)
        verify(widget.item !== null)
        tryVerify(function () {
            return widget.item.panel !== null
        })
    }

    function init() {
        SessionRegistry.resetForTests()
    }

    function cleanup() {
        widget.active = false
        SessionRegistry.resetForTests()
    }

    function test_configure_scrcpy_forwards_reserved_args_to_panel() {
        loadWidget()
        var seen = null
        widget.item.panel = {
            setScrcpyConfiguration: function (revision, args) {
                seen = {
                    revision: revision,
                    args: args
                }
                return false
            }
        }

        verify(!widget.item.configureScrcpy("not-a-revision",
                                            encodeEnvelope(["--keep-active"])))
        compare(seen, null)

        verify(!widget.item.configureScrcpy("0123456789abcdef", "!!!"))
        compare(seen, null)

        verify(!widget.item.configureScrcpy(
                   "0123456789abcdef", encodeEnvelope(["--serial"])))
        compare(seen, {
                    revision: "0123456789abcdef",
                    args: ["--serial"]
                })
        compare(widget.item.validScrcpyArguments, undefined)
    }
}
