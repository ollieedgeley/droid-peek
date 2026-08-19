import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "SubmapDispatch"
    when: windowShown
    visible: true
    width: 720
    height: 450

    readonly property string shortcutsUnavailableTitle:
        "Android keyboard shortcuts unavailable"
    readonly property string shortcutsUnavailableDescription:
        "Desktop phone shortcuts could not be activated. The phone connection may still be retained."

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

    function beginStartedSession() {
        var state = objectNamed("pairingState")
        verify(state !== null)
        state.reset()
        state.receiveLine(event("ready", {
            sessionGeneration: "0",
            hasTrustedDevice: true,
            scrcpyRevision: "cbf29ce484222325",
            screenOffRequested: false,
            preferences: {
                keepConnected: true,
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
        compare(state.hasTrustedDevice, true)
        return state
    }

    function drainStartedRequests(exitCode) {
        var process = objectNamed("submapProcess")
        var pending = process.startedRequests.slice()
        for (var index = 0; index < pending.length; ++index)
            process.exited(exitCode)
        compare(process.startedRequests.length, 0)
    }

    function becomeInteractive(controller) {
        if (controller.applicationState === "interactive")
            controller.applicationState = "closed"
        controller.applicationState = "interactive"
        compare(controller.desiredSubmap, "omarchy-android")
    }

    function emitSupersededExits(process, controller, exitCode) {
        var pending = process.startedRequests.slice()
        verify(pending.length >= 1)
        for (var index = 0; index < pending.length - 1; ++index) {
            verify(!controller.isCurrentRequest(pending[index].requestId))
            process.exited(exitCode)
        }
    }

    function init() {
        compare(panelLoader.status, Loader.Ready)
        panelLoader.item.open()
        compare(panelLoader.item.opened, true)
        var root = panelLoader.item
        root.settingsOpen = false
        root.managementOpen = false
        beginStartedSession()
        var process = objectNamed("submapProcess")
        var controller = objectNamed("submapController")
        verify(process !== null)
        verify(controller !== null)
        drainStartedRequests(0)
        controller.applicationState = "closed"
        controller.androidModeShortcuts = true
        controller.lastDispatchedSubmap = "reset"
        drainStartedRequests(0)
    }

    function test_stale_reset_after_reopen_does_not_fail_closed() {
        var controller = objectNamed("submapController")
        var process = objectNamed("submapProcess")
        var state = objectNamed("pairingState")

        becomeInteractive(controller)
        compare(process.dispatchedSubmap, "omarchy-android")

        controller.closePanel()
        controller.helperRestarted()
        becomeInteractive(controller)
        compare(process.dispatchedSubmap, "omarchy-android")
        verify(process.startedRequests.length >= 2)
        compare(process.startedRequests[process.startedRequests.length - 1].submap,
                "omarchy-android")

        emitSupersededExits(process, controller, 1)

        compare(state.localIntegrationAvailable, true)
        verify(state.statusTitle !== shortcutsUnavailableTitle)
        compare(state.pairingStage !== "local-integration-failed", true)
        compare(process.startedRequests.length, 1)
        verify(controller.isCurrentRequest(process.startedRequests[0].requestId))
    }

    function test_successful_current_activation_does_not_fail_closed() {
        var controller = objectNamed("submapController")
        var process = objectNamed("submapProcess")
        var state = objectNamed("pairingState")

        becomeInteractive(controller)
        emitSupersededExits(process, controller, 0)
        compare(process.startedRequests[0].submap, "omarchy-android")
        verify(controller.isCurrentRequest(process.startedRequests[0].requestId))

        process.exited(0)

        compare(process.startedRequests.length, 0)
        compare(state.localIntegrationAvailable, true)
        verify(state.statusTitle !== shortcutsUnavailableTitle)
        compare(state.pairingStage !== "local-integration-failed", true)
    }

    function test_genuine_current_activation_failure_fails_closed() {
        var controller = objectNamed("submapController")
        var process = objectNamed("submapProcess")
        var state = objectNamed("pairingState")

        becomeInteractive(controller)
        emitSupersededExits(process, controller, 1)
        compare(state.localIntegrationAvailable, true)
        compare(process.startedRequests[0].submap, "omarchy-android")
        verify(controller.isCurrentRequest(process.startedRequests[0].requestId))

        process.exited(1)

        compare(state.localIntegrationAvailable, false)
        compare(state.pairingStage, "local-integration-failed")
        compare(state.statusTitle, shortcutsUnavailableTitle)
        compare(state.statusDescription, shortcutsUnavailableDescription)
        compare(state.helperReady, true)
        compare(state.hasTrustedDevice, true)

        var tag = objectNamed("setupHeadingTag")
        verify(tag !== null)
        tryCompare(tag, "text", "Shortcuts")
    }

    function test_close_always_dispatches_reset() {
        var controller = objectNamed("submapController")
        var process = objectNamed("submapProcess")

        becomeInteractive(controller)
        compare(process.dispatchedSubmap, "omarchy-android")

        controller.closePanel()

        compare(process.dispatchedSubmap, "reset")
        compare(controller.lastDispatchedSubmap, "")
        compare(process.startedRequests[process.startedRequests.length - 1].submap,
                "reset")
        verify(controller.desiredSubmap !== "omarchy-android"
               || process.dispatchedSubmap === "reset")
    }
}
