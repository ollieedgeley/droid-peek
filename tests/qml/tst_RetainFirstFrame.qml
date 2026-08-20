import QtQuick
import QtMultimedia
import QtTest

TestCase {
    id: testCase
    name: "RetainFirstFrame"
    when: windowShown
    visible: true
    width: 720
    height: 450
    property var pendingGrabCallback: null
    property size lastGrabSize: Qt.size(0, 0)
    property int grabCount: 0


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
        tryVerify(function () {
            return panelLoader.item.acceptedHelperEpoch !== ""
        })
        var root = panelLoader.item
        root.settingsOpen = false
        root.managementOpen = false
        root.hostWidget = null
        var dialog = objectNamed("startOverDialog")
        if (dialog !== null)
            dialog.opened = false
        var state = objectNamed("pairingState")
        verify(state !== null)
        commandSpy.target = state
        commandSpy.clear()
    }

    function cleanup() {
        var preview = panelLoader.item !== null ? panelLoader.item.phonePreview : null
        if (preview !== null)
            preview.retainedImageGrabber = null
        pendingGrabCallback = null
        lastGrabSize = Qt.size(0, 0)
        grabCount = 0
        if (panelLoader.item !== null)
            panelLoader.item.hostWidget = null
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

    function waitForCapturePipeline(preview, expectedCaptureEpoch) {
        tryVerify(function () {
            return !preview.capturePipelineCreationPending
                    && preview.capturePipeline
                    && preview.capturePipeline.epoch === expectedCaptureEpoch
        }, 500)
    }

    function establishCaptureReadiness(root, state, generation) {
        state.firstFrameTimeoutMs = 500
        tryVerify(function () {
            return root.phonePreview !== null
        })
        var preview = root.phonePreview
        preview.capturePipelineReleaseDelayMs = 1
        preview.videoInputs = [{
            id: preview.deviceId,
            description: preview.deviceDescription
        }]
        tryCompare(preview, "captureRequested", true)
        tryCompare(preview, "deviceAvailable", true)
        var preRefreshEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   preRefreshEpoch, root.acceptedHelperEpoch, generation,
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   preRefreshEpoch, root.acceptedHelperEpoch, generation,
                   1080, 2400, true))
        compare(preview.captureEpoch, preRefreshEpoch)
        wait(0)

        var readyCaptureEpoch = preview.captureEpoch
        compare(readyCaptureEpoch, preRefreshEpoch + 1)
        waitForCapturePipeline(preview, readyCaptureEpoch)
        verify(preview.acceptCaptureSource(
                   readyCaptureEpoch, root.acceptedHelperEpoch, generation,
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   readyCaptureEpoch, root.acceptedHelperEpoch, generation,
                   1080, 2400, true))
        tryCompare(preview, "firstValidFrameReceived", true)
        tryCompare(state, "previewReadyGeneration", generation)
        return {
            preview: preview,
            captureEpoch: readyCaptureEpoch
        }
    }
    function installGrabber(preview, starts) {
        pendingGrabCallback = null
        lastGrabSize = Qt.size(0, 0)
        grabCount = 0
        preview.retainedImageGrabber = function (callback, targetSize) {
            testCase.grabCount += 1
            testCase.lastGrabSize = targetSize
            if (!starts)
                return false
            testCase.pendingGrabCallback = callback
            return true
        }
    }

    function completeGrab(result) {
        verify(pendingGrabCallback !== null)
        var callback = pendingGrabCallback
        pendingGrabCallback = null
        callback(result)
    }


    function test_retain_close_waits_for_one_grab_and_reopens_same_framed_session() {
        var root = panelLoader.item
        var state = beginStartedSession(true)
        var readiness = establishCaptureReadiness(root, state, "1")
        var preview = readiness.preview
        var helperEpoch = root.acceptedHelperEpoch
        var sessionGeneration = state.sessionGeneration
        var captureEpoch = readiness.captureEpoch
        var fallback = objectNamed("fallbackStartOverButton")
        var model = objectNamed("applicationStateModel")
        var loading = objectNamed("previewLoadingTreatment")
        var videoOutput = objectNamed("phoneVideoOutput")
        var retainedImage = objectNamed("retainedPreviewImage")
        var toolbar = objectNamed("phoneToolbar")
        var quickAction = objectNamed("quickActionButton-back")
        verify(fallback !== null)
        verify(model !== null)
        verify(loading !== null)
        verify(videoOutput !== null)
        verify(retainedImage !== null)
        verify(toolbar !== null)
        verify(quickAction !== null)
        installGrabber(preview, true)
        commandSpy.clear()

        root.requestClose()
        compare(root.opened, true)
        compare(root.retainedClosePending, true)
        compare(grabCount, 1)
        compare(lastGrabSize.width, Math.round(videoOutput.width))
        compare(lastGrabSize.height, Math.round(videoOutput.height))

        root.requestClose()
        compare(root.opened, true)
        compare(grabCount, 1)

        completeGrab({ url: "" })
        compare(root.opened, false)
        compare(root.retainedClosePending, false)
        verify(root.phonePreview !== null)
        compare(root.phonePreview, preview)
        compare(root.acceptedHelperEpoch, helperEpoch)
        compare(preview.helperEpoch, helperEpoch)
        compare(preview.sessionGeneration, sessionGeneration)
        compare(state.sessionGeneration, sessionGeneration)
        compare(preview.captureEpoch, captureEpoch)
        compare(root.previewCaptureWanted, true)
        compare(preview.captureRequested, true)
        compare(preview.retainedImageAvailable, true)
        verify(retainedImage.z > videoOutput.z)
        compare(preview.firstValidFrameReceived, true)
        compare(preview.captureAvailable, true)
        compare(state.sessionStarted, true)
        compare(commandSpy.count, 0)
        compare(fallback.visible, false)
        // Sink frames continue while the panel is closed. They must not
        // discard the only presentation that survives QQuickWindow teardown.
        verify(preview.acceptRenderedFrame(
                   captureEpoch, helperEpoch, sessionGeneration,
                   1080, 2400, true))
        compare(preview.retainedImageAvailable, true)
        compare(preview.retainedImageReleasePending, false)

        root.open()
        compare(root.opened, true)
        compare(root.phonePreview, preview)
        compare(root.acceptedHelperEpoch, helperEpoch)
        compare(state.sessionGeneration, sessionGeneration)
        compare(preview.captureEpoch, captureEpoch)
        compare(preview.helperEpoch, helperEpoch)
        compare(preview.sessionGeneration, sessionGeneration)
        tryCompare(model, "previewPresentationUsable", true)
        retainedImage = objectNamed("retainedPreviewImage")
        videoOutput = objectNamed("phoneVideoOutput")
        verify(retainedImage !== null)
        verify(videoOutput !== null)
        compare(retainedImage.visible, true)
        verify(retainedImage.z > videoOutput.z)
        compare(loading.visible, false)
        compare(toolbar.visible, true)
        compare(toolbar.enabled, false)
        compare(quickAction.enabled, false)
        compare(preview.inputActive, false)
        compare(preview.retainedImageAvailable, true)
        compare(commandSpy.count, 0)
        root.requestClose()
        compare(root.opened, false)
        compare(grabCount, 1)
        compare(root.retainedClosePending, false)
        root.open()
        compare(root.opened, true)
        compare(preview.retainedImageAvailable, true)

        verify(preview.acceptRenderedFrame(
                   captureEpoch, helperEpoch, sessionGeneration,
                   1080, 2400, true))
        compare(preview.retainedImageAvailable, true)
        compare(preview.retainedImageReleasePending, true)
        compare(toolbar.enabled, false)
        verify(preview.completeRetainedImageRelease())
        compare(preview.retainedImageAvailable, false)
        compare(retainedImage.visible, false)
        tryCompare(root, "applicationState", "interactive")
        compare(toolbar.enabled, true)
        verify(state.statusTitle !== "Preview failed")
    }

    function test_capture_error_clears_successful_retained_image() {
        var root = panelLoader.item
        var state = beginStartedSession(true)
        var readiness = establishCaptureReadiness(root, state, "1")
        var preview = readiness.preview
        var captureEpoch = readiness.captureEpoch
        installGrabber(preview, true)

        verify(preview.captureRetainedImage())
        completeGrab({ url: "" })
        compare(preview.retainedImageAvailable, true)

        preview.handleCaptureFailure(captureEpoch)
        compare(preview.retainedImageAvailable, false)
        compare(preview.firstValidFrameReceived, false)
        compare(preview.captureAvailable, false)
        compare(preview.displayWidth, 0)
        compare(preview.displayHeight, 0)
    }

    function test_stale_capture_completion_cannot_close_current_identity_data() {
        return [
            { tag: "capture epoch", identity: "capture" },
            { tag: "helper epoch", identity: "helper" },
            { tag: "session generation", identity: "session" }
        ]
    }

    function test_stale_capture_completion_cannot_close_current_identity(data) {
        var root = panelLoader.item
        var state = beginStartedSession(true)
        var readiness = establishCaptureReadiness(root, state, "1")
        var preview = readiness.preview
        commandSpy.clear()
        installGrabber(preview, true)

        root.requestClose()
        compare(root.retainedClosePending, true)
        compare(root.opened, true)
        var staleCallback = pendingGrabCallback
        verify(staleCallback !== null)

        if (data.identity === "capture")
            preview.recreateCapturePipeline()
        else if (data.identity === "helper")
            preview.helperEpoch = String(Number(preview.helperEpoch) + 1)
        else
            preview.sessionGeneration = String(Number(preview.sessionGeneration) + 1)
        waitForCapturePipeline(preview, preview.captureEpoch)

        compare(root.retainedClosePending, false)
        compare(root.opened, true)
        compare(preview.retainedImageAvailable, false)
        staleCallback({ url: "" })
        compare(root.opened, true)
        compare(preview.retainedImageAvailable, false)
        compare(commandSpy.count, 0)
    }

    function test_pending_capture_cannot_close_reclaimed_host() {
        var root = panelLoader.item
        var state = beginStartedSession(true)
        var readiness = establishCaptureReadiness(root, state, "1")
        var preview = readiness.preview
        var originalHost = { name: "original" }
        var replacementHost = { name: "replacement" }
        root.claimHost(originalHost, anchorItem, topBar)
        commandSpy.clear()
        installGrabber(preview, true)

        root.requestClose()
        compare(root.retainedClosePending, true)
        var staleCallback = pendingGrabCallback
        verify(staleCallback !== null)

        root.claimHost(replacementHost, anchorItem, topBar)
        compare(root.retainedClosePending, false)
        compare(preview.retainedImageCapturePending, false)
        compare(root.opened, true)

        root.requestClose()
        compare(root.retainedClosePending, true)
        var replacementCallback = pendingGrabCallback
        verify(replacementCallback !== null)
        verify(replacementCallback !== staleCallback)

        staleCallback({ url: "" })
        compare(root.retainedClosePending, true)
        compare(root.opened, true)
        replacementCallback({ url: "" })
        compare(root.retainedClosePending, false)
        compare(root.opened, false)
        compare(root.hostWidget, replacementHost)
        compare(preview.retainedImageAvailable, true)
        compare(commandSpy.count, 0)
    }

    function test_unframed_preview_rejects_image_capture() {
        var root = panelLoader.item
        beginStartedSession(true)
        tryVerify(function () {
            return root.phonePreview !== null
        })
        var preview = root.phonePreview
        installGrabber(preview, true)

        compare(preview.firstValidFrameReceived, false)
        compare(preview.captureRetainedImage(), false)
        compare(preview.retainedImageAvailable, false)
        compare(grabCount, 0)
    }

    function test_synchronous_grab_rejection_closes_immediately() {
        var root = panelLoader.item
        var state = beginStartedSession(true)
        var readiness = establishCaptureReadiness(root, state, "1")
        var preview = readiness.preview
        installGrabber(preview, false)
        commandSpy.clear()

        root.requestClose()
        compare(grabCount, 1)
        compare(root.retainedClosePending, false)
        compare(root.opened, false)
        compare(preview.retainedImageAvailable, false)
        compare(commandSpy.count, 0)
    }

    function test_keep_connected_off_close_stops_immediately_without_grab() {
        var root = panelLoader.item
        var state = beginStartedSession(false)
        tryVerify(function () {
            return root.phonePreview !== null
        })
        var preview = root.phonePreview
        installGrabber(preview, true)
        commandSpy.clear()

        root.requestClose()
        compare(root.opened, false)
        compare(grabCount, 0)
        compare(commandSpy.count, 1)
        compare(commandAt(0).type, "stop-session")
        compare(state.sessionStarted, true)
        verify(state.statusTitle !== "Preview failed")
    }
}
