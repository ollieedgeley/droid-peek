import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "PanelHelperProcess"
    when: windowShown
    visible: true
    width: 720
    height: 450

    Item {
        id: anchorItem
        width: 720
        height: 450
        property real outputWidth: 1440
        property real outputHeight: 900
        property real outputScale: 2
    }

    QtObject {
        id: topBar
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
        id: panelLoader
        source: Qt.resolvedUrl("../../Panel.qml")
        onLoaded: {
            item.anchorItem = anchorItem
            item.bar = topBar
            item.open()
        }
    }

    function objectNamed(name) {
        var seen = []
        var pending = [testCase]
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

    function readyLine(epoch) {
        return JSON.stringify({
            version: 11,
            type: "ready",
            helperEpoch: epoch,
            sessionGeneration: "0",
            hasTrustedDevice: false,
            scrcpyRevision: "cbf29ce484222325",
            screenOffRequested: false,
            preferences: {
                keepConnected: false,
                previewScale: 100,
                videoQuality: "high",
                quickActions: ["back", "home", "recent-apps"],
                androidModeShortcuts: true
            }
        })
    }

    function test_open_write_path_delivers_ready_into_pairing_state() {
        compare(panelLoader.status, Loader.Ready)
        panelLoader.item.open()
        compare(panelLoader.item.opened, true)
        tryVerify(function () {
            return panelLoader.item.acceptedHelperEpoch !== ""
        })

        var helper = findHelperProcess(panelLoader.item)
        verify(helper !== null)
        wait(20)
        compare(helper.running, true)
        verify(helper.command.indexOf("--version") < 0)
        verify(helper.command.indexOf("--helper-epoch") >= 0)
        verify(helper.command.indexOf(panelLoader.item.acceptedHelperEpoch) >= 0)

        var state = objectNamed("pairingState")
        verify(state !== null)
        compare(state.helperReady, false)

        helper.stdout.read(readyLine(panelLoader.item.acceptedHelperEpoch))

        compare(state.helperReady, true)
        compare(helper.running, true)
        compare(helper.writtenLines.length, 1)
        var sent = JSON.parse(helper.writtenLines[0])
        compare(sent, {
            version: 11,
            type: "start-qr-pairing",
            helperEpoch: panelLoader.item.acceptedHelperEpoch
        })
    }
}
