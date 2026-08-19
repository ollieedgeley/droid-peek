import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "RetainFirstFrame"
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
        function toggleTransparency() {
            transparent = !transparent
        }
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

    SignalSpy {
        id: commandSpy
        signalName: "commandRequested"
    }

    function objectsNamed(name) {
        var matches = []
        var seen = []
        var pending = [testCase]
        while (pending.length > 0) {
            var object = pending.pop()
            if (!object || seen.indexOf(object) !== -1)
                continue
            seen.push(object)
            if (object.objectName === name)
                matches.push(object)
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
        return matches
    }

    function objectNamed(name) {
        var matches = objectsNamed(name)
        return matches.length > 0 ? matches[0] : null
    }

    function event(type, values) {
        var result = values || {}
        result.version = 11
        result.type = type
        result.helperEpoch = panelLoader.item.acceptedHelperEpoch
        return JSON.stringify(result)
    }

    function commandAt(index) {
        return JSON.parse(commandSpy.signalArguments[index][0])
    }

    function stopSessionCount() {
        var count = 0
        for (var index = 0; index < commandSpy.count; ++index) {
            if (commandAt(index).type === "stop-session")
                count += 1
        }
        return count
    }

    function beginStartedSession(keepConnected) {
        var state = objectNamed("pairingState")
        verify(state !== null)
        state.reset()
        state.firstFrameTimeoutMs = 20
        state.receiveLine(event("ready", {
            sessionGeneration: "0",
            hasTrustedDevice: true,
            scrcpyRevision: "cbf29ce484222325",
            screenOffRequested: false,
            preferences: {
                keepConnected: keepConnected,
                previewScale: 100,
                videoQuality: "high",
                quickActions: ["back", "home", "recent-apps"],
                androidModeShortcuts: true
            }
        }))
        state.receiveLine(event("connected", { sessionGeneration: "1" }))
        state.receiveLine(event("session-started", {
            sessionGeneration: "1",
            screenOffEnabled: false
        }))
        compare(state.sessionStarted, true)
        compare(state.keepConnected, keepConnected)
        compare(state.firstFrameTimeoutMs, 20)
        return state
    }

    function init() {
        compare(panelLoader.status, Loader.Ready)
        panelLoader.item.open()
        compare(panelLoader.item.opened, true)
        var root = panelLoader.item
        root.settingsOpen = false
        root.managementOpen = false
        var dialog = objectNamed("startOverDialog")
        if (dialog !== null)
            dialog.opened = false
        var state = objectNamed("pairingState")
        verify(state !== null)
        commandSpy.target = state
        commandSpy.clear()
    }

    function cleanup() {
        var state = objectNamed("pairingState")
        if (state !== null) {
            state.keepConnected = true
            state.reset()
        }
        commandSpy.clear()
        if (panelLoader.item !== null && !panelLoader.item.opened)
            panelLoader.item.open()
    }

    function test_retain_close_does_not_stop_session() {
        var root = panelLoader.item
        var state = beginStartedSession(true)
        tryVerify(function () {
            return root.phonePreview !== null
        })
        compare(state.previewSurfaceMounted, true)
        commandSpy.clear()

        root.close()
        compare(root.opened, false)
        compare(root.phonePreview, null)
        compare(state.previewSurfaceMounted, false)

        wait(state.firstFrameTimeoutMs + 30)
        compare(stopSessionCount(), 0)
        compare(state.sessionStarted, true)
        verify(state.statusTitle !== "Preview failed")
    }

    function test_reopen_remounts_and_may_fail_closed() {
        var root = panelLoader.item
        var state = beginStartedSession(true)
        tryVerify(function () {
            return root.phonePreview !== null
        })
        commandSpy.clear()

        root.close()
        compare(state.previewSurfaceMounted, false)
        wait(state.firstFrameTimeoutMs + 30)
        compare(stopSessionCount(), 0)
        compare(state.sessionStarted, true)

        root.open()
        compare(root.opened, true)
        tryVerify(function () {
            return root.phonePreview !== null
        })
        tryCompare(state, "previewSurfaceMounted", true)

        tryCompare(state, "statusTitle", "Preview failed")
        compare(stopSessionCount(), 1)
        compare(state.sessionStarted, false)
    }

    function acknowledgeFirstFrame(root, state, generation) {
        tryVerify(function () {
            return root.phonePreview !== null
        })
        var preview = root.phonePreview
        preview.videoInputs = [{
            id: preview.deviceId,
            description: preview.deviceDescription
        }]
        tryCompare(preview, "captureRequested", true)
        tryCompare(preview, "deviceAvailable", true)
        var captureEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   captureEpoch, root.acceptedHelperEpoch, generation,
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   captureEpoch, root.acceptedHelperEpoch, generation,
                   1080, 2400))
        tryCompare(preview, "firstValidFrameReceived", true)
        tryCompare(state, "previewReadyGeneration", generation)
        return preview
    }

    function test_retain_after_first_frame_reopens_ready() {
        var root = panelLoader.item
        var state = beginStartedSession(true)
        var preview = acknowledgeFirstFrame(root, state, "1")
        commandSpy.clear()

        root.close()
        compare(root.opened, false)
        verify(root.phonePreview !== null)
        compare(root.phonePreview, preview)
        compare(root.previewCaptureWanted, true)
        compare(preview.captureRequested, true)
        compare(preview.firstValidFrameReceived, true)
        compare(state.sessionStarted, true)
        compare(stopSessionCount(), 0)

        root.open()
        compare(root.opened, true)
        compare(root.phonePreview, preview)
        tryCompare(root, "applicationState", "interactive")
        compare(preview.firstValidFrameReceived, true)
        compare(stopSessionCount(), 0)
        verify(state.statusTitle !== "Preview failed")
    }

    function test_keep_connected_off_close_stops_immediately() {
        var root = panelLoader.item
        var state = beginStartedSession(false)
        tryVerify(function () {
            return root.phonePreview !== null
        })
        commandSpy.clear()

        root.close()
        compare(root.opened, false)
        compare(commandSpy.count, 1)
        compare(commandAt(0).type, "stop-session")
        compare(state.sessionStarted, true)
        verify(state.statusTitle !== "Preview failed")
    }
}
