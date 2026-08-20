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

    Component {
        id: forwardingPanelComponent

        QtObject {
            property int phoneCalls: 0
            property var phoneTarget: null
            property bool phoneResult: true
            property int scrcpyCalls: 0
            property var scrcpy: null
            property bool scrcpyResult: true

            function acceptPhoneTarget(request) {
                phoneCalls += 1
                phoneTarget = request
                return phoneResult
            }

            function setScrcpyConfiguration(revision, args) {
                scrcpyCalls += 1
                scrcpy = {
                    revision: revision,
                    args: args
                }
                return scrcpyResult
            }
        }
    }

    function encodeEnvelope(value) {
        var json = JSON.stringify(value)
        var binary = unescape(encodeURIComponent(json))
        return Qt.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "")
    }

    function encodeRaw(text) {
        var binary = unescape(encodeURIComponent(text))
        return Qt.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
                    /=+$/g, "")
    }

    function repeatedChar(ch, count) {
        var result = ""
        for (var index = 0; index < count; ++index)
            result += ch
        return result
    }

    function installForwardingPanel() {
        var panel = forwardingPanelComponent.createObject(testCase)
        verify(panel !== null)
        SessionRegistry.panel = panel
        return panel
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
        var panel = installForwardingPanel()
        panel.scrcpyResult = false
        loadWidget()
        compare(widget.item.panel, panel)
        compare(panel, SessionRegistry.panel)

        verify(!widget.item.configureScrcpy("not-a-revision",
                                            encodeEnvelope(["--keep-active"])))
        compare(panel.scrcpy, null)

        verify(!widget.item.configureScrcpy("0123456789abcdef", "!!!"))
        compare(panel.scrcpy, null)

        verify(!widget.item.configureScrcpy(
                   "0123456789abcdef", encodeEnvelope(["--serial"])))
        compare(panel.scrcpyCalls, 1)
        compare(panel.scrcpy, {
                    revision: "0123456789abcdef",
                    args: ["--serial"]
                })
        compare(widget.item.validScrcpyArguments, undefined)
    }

    function test_open_close_and_toggle_shared_panel() {
        loadWidget()
        var panel = widget.item.panel
        compare(panel, SessionRegistry.panel)
        compare(widget.item.opened, false)

        widget.item.open()
        compare(widget.item.opened, true)
        compare(panel.hostWidget, widget.item)
        compare(panel.bar, sharedBar)
        verify(panel.anchorItem !== null)

        widget.item.close()
        compare(widget.item.opened, false)

        widget.item.togglePanel()
        compare(widget.item.opened, true)
        widget.item.togglePanel()
        compare(widget.item.opened, false)
    }

    function test_close_prefers_request_close() {
        loadWidget()
        var calls = {
            requestClose: 0,
            close: 0,
            requestCloseArguments: -1
        }
        widget.item.panel = {
            requestClose: function () {
                calls.requestClose += 1
                calls.requestCloseArguments = arguments.length
            },
            close: function () {
                calls.close += 1
            }
        }

        widget.item.close()

        compare(calls.requestClose, 1)
        compare(calls.requestCloseArguments, 0)
        compare(calls.close, 0)
    }

    function test_close_falls_back_to_panel_close() {
        loadWidget()
        var calls = {
            close: 0,
            closeArguments: -1
        }
        widget.item.panel = {
            close: function () {
                calls.close += 1
                calls.closeArguments = arguments.length
            }
        }

        widget.item.close()

        compare(calls.close, 1)
        compare(calls.closeArguments, 0)
    }

    function test_malformed_and_oversized_envelopes_are_rejected() {
        var panel = installForwardingPanel()
        loadWidget()
        compare(widget.item.panel, panel)
        compare(panel, SessionRegistry.panel)
        var revision = "0123456789abcdef"

        verify(!widget.item.phoneTarget(""))
        verify(!widget.item.phoneTarget("!!!"))
        verify(!widget.item.phoneTarget("+"))
        verify(!widget.item.phoneTarget(encodeRaw("not-json")))
        verify(!widget.item.phoneTarget(repeatedChar("a", 4097)))
        compare(panel.phoneCalls, 0)
        compare(panel.phoneTarget, null)

        verify(!widget.item.configureScrcpy(revision, ""))
        verify(!widget.item.configureScrcpy(revision, "!!!"))
        verify(!widget.item.configureScrcpy(revision, encodeRaw("not-json")))
        verify(!widget.item.configureScrcpy(revision, repeatedChar("a", 24001)))
        compare(panel.scrcpyCalls, 0)
        compare(panel.scrcpy, null)
    }

    function test_phone_target_forwards_only_to_shared_panel() {
        var panel = installForwardingPanel()
        loadWidget()
        compare(widget.item.panel, panel)
        compare(panel, SessionRegistry.panel)
        var request = {
            requestId: "req-1",
            target: "android.navigate.home",
            expiresAtUnixMs: 1700000000000
        }

        verify(widget.item.phoneTarget(encodeEnvelope(request)))
        compare(panel.phoneCalls, 1)
        compare(panel.phoneTarget, request)
        compare(panel.scrcpyCalls, 0)
        compare(widget.item.pendingPhoneTarget, undefined)
        compare(typeof widget.item.acceptPhoneTarget, "undefined")
    }

    function test_configure_scrcpy_forwards_only_to_shared_panel() {
        var panel = installForwardingPanel()
        loadWidget()
        compare(widget.item.panel, panel)
        compare(panel, SessionRegistry.panel)
        var revision = "0123456789abcdef"

        verify(widget.item.configureScrcpy(revision,
                                           encodeEnvelope(["--keep-active"])))
        compare(panel.scrcpyCalls, 1)
        compare(panel.scrcpy, {
                    revision: revision,
                    args: ["--keep-active"]
                })
        compare(panel.phoneCalls, 0)
        compare(widget.item.validScrcpyArguments, undefined)
    }
}
