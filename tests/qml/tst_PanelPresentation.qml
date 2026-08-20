import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "PanelPresentation"
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
        property int transparencyToggleCount: 0

        function showTooltip(item, text, position) {}
        function hideTooltip() {}
        function registerClickTarget(item) {}
        function unregisterClickTarget(item) {}
        function toggleTransparency() {
            transparent = !transparent
            transparencyToggleCount += 1
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
        id: panelCommandSpy
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
    function objectWithText(text) {
        var seen = []
        var pending = [testCase]
        while (pending.length > 0) {
            var object = pending.pop()
            if (!object || seen.indexOf(object) !== -1)
                continue
            seen.push(object)
            if (object.text === text)
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
    function objectWithProperty(propertyName) {
        var seen = []
        var pending = [testCase]
        while (pending.length > 0) {
            var object = pending.pop()
            if (!object || seen.indexOf(object) !== -1)
                continue
            seen.push(object)
            if (object[propertyName] !== undefined)
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


    function presentationGeometry() {
        var panel = objectNamed("boundedKeyboardPanel")
        var card = objectNamed("previewCard")
        var content = objectNamed("panelContent")
        return {
            panelWidth: panel.contentWidth,
            panelHeight: panel.contentHeight,
            cardWidth: card.width,
            cardHeight: card.height,
            contentWidth: content.width,
            contentHeight: content.height
        }
    }

    function comparePresentationGeometry(expected) {
        var actual = presentationGeometry()
        compare(actual.panelWidth, expected.panelWidth)
        compare(actual.panelHeight, expected.panelHeight)
        compare(actual.cardWidth, expected.cardWidth)
        compare(actual.cardHeight, expected.cardHeight)
        compare(actual.contentWidth, expected.contentWidth)
        compare(actual.contentHeight, expected.contentHeight)
    }
    function compareConnectingPresentation(expectedGeometry) {
        var root = panelLoader.item
        var model = objectNamed("applicationStateModel")
        var card = objectNamed("previewCard")
        var loading = objectNamed("previewLoadingTreatment")
        var toolbar = objectNamed("phoneToolbar")
        tryCompare(model, "connectionPresentationActive", true)
        tryCompare(model, "captureSurfaceRequired", true)
        tryCompare(root, "applicationState", "recovering")
        compare(model.previewUsable, false)
        verify(card.visible)
        verify(loading.visible)
        verify(!toolbar.visible)
        comparePresentationGeometry(expectedGeometry)
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
                keepConnected: false,
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
        var dialog = objectNamed("startOverDialog")
        if (dialog !== null)
            dialog.opened = false
        panelCommandSpy.target = null
        panelCommandSpy.clear()
        var model = objectNamed("applicationStateModel")
        model.captureAvailable = Qt.binding(function () {
            return root.phonePreview !== null
                    && root.phonePreview.captureAvailable
        })
        model.captureActive = Qt.binding(function () {
            return root.phonePreview !== null && root.phonePreview.active
        })
        model.firstValidFrameReceived = Qt.binding(function () {
            return root.phonePreview !== null
                    && root.phonePreview.firstValidFrameReceived
        })
        model.displayWidth = Qt.binding(function () {
            return root.phonePreview !== null ? root.phonePreview.displayWidth : 0
        })
        model.displayHeight = Qt.binding(function () {
            return root.phonePreview !== null ? root.phonePreview.displayHeight : 0
        })
        model.previewInputEnabled = Qt.binding(function () {
            return root.phonePreview !== null
                    && root.phonePreview.previewInputEnabled
        })
        beginStartedSession()
        tryCompare(panelLoader.item, "applicationState", "recovering")
    }

    function test_starting_preview_keeps_full_non_scrolling_surface() {
        var root = panelLoader.item
        var panel = objectNamed("boundedKeyboardPanel")
        var content = objectNamed("panelContent")
        var unit = objectNamed("interactivePhoneUnit")
        var toolbar = objectNamed("phoneToolbar")
        var previewCard = objectNamed("previewCard")
        var toolbarSpacer = objectNamed("loadingToolbarSpacer")
        var background = objectNamed("previewCardBackground")
        var loading = objectNamed("previewLoadingTreatment")
        var preview = root.phonePreview

        verify(panel !== null)
        verify(content !== null)
        verify(unit !== null)
        verify(toolbar !== null)
        verify(previewCard !== null)
        verify(toolbarSpacer !== null)
        verify(background !== null)
        verify(loading !== null)
        verify(preview !== null)
        verify(unit.visible,
               "unit hidden: captureSurfaceRequired="
               + objectNamed("applicationStateModel").captureSurfaceRequired
               + " toolbarVisible=" + toolbar.visible)
        verify(previewCard.visible,
               "preview hidden: captureSurfaceRequired="
               + objectNamed("applicationStateModel").captureSurfaceRequired)
        verify(loading.visible,
               "loading hidden: previewUsable="
               + objectNamed("applicationStateModel").previewUsable
               + " captureSurfaceRequired="
               + objectNamed("applicationStateModel").captureSurfaceRequired)
        verify(loading.running)
        compare(loading.foreground, root.contentForeground)
        verify(preview.captureRequested)
        compare(unit.spacing, 0)
        tryCompare(toolbarSpacer, "visible", true)
        tryCompare(previewCard, "y", toolbar.implicitHeight)
        compare(background.y + background.radius, 0)
        compare(previewCard.height,
                panel.availableCardHeight - panel.verticalContentInset
                - toolbar.implicitHeight)
        tryCompare(content, "implicitHeight", unit.implicitHeight)
        tryCompare(content, "height", content.implicitHeight)

        var loadingCenter = loading.mapToItem(previewCard,
                                              loading.width / 2,
                                              loading.height / 2)
        fuzzyCompare(loadingCenter.x, previewCard.width / 2, 1)
        fuzzyCompare(loadingCenter.y, previewCard.height / 2, 1)
    }

    function test_loading_hides_only_after_preview_becomes_usable() {
        var model = objectNamed("applicationStateModel")
        var loading = objectNamed("previewLoadingTreatment")
        var previewCard = objectNamed("previewCard")
        verify(model !== null)
        verify(loading.visible,
               "loading hidden: previewUsable=" + model.previewUsable
               + " captureSurfaceRequired=" + model.captureSurfaceRequired
               + " sessionStarted=" + model.sessionStarted)

        model.captureAvailable = true
        model.captureActive = true
        model.firstValidFrameReceived = true
        model.displayWidth = 1080
        model.displayHeight = 2400
        model.previewInputEnabled = true

        tryCompare(model, "previewUsable", true)
        tryCompare(loading, "visible", false)
        verify(previewCard.visible)
        var toolbar = objectNamed("phoneToolbar")
        tryCompare(previewCard, "y", toolbar.y + toolbar.height)
    }

    function test_start_over_confirmation_hides_interactive_toolbar() {
        var root = panelLoader.item
        var unit = objectNamed("interactivePhoneUnit")
        var toolbar = objectNamed("phoneToolbar")
        var dialog = objectNamed("startOverDialog")
        verify(unit !== null)
        verify(toolbar !== null)
        verify(dialog !== null)

        root.requestStartOver()
        tryCompare(root, "applicationState", "management")
        verify(dialog.opened)
        verify(!unit.visible)
        verify(!toolbar.visible)

        dialog.opened = false
        root.managementOpen = false
    }

    function test_settings_owns_the_only_visible_start_over_action() {
        var root = panelLoader.item
        root.openSettings()
        tryCompare(root, "applicationState", "management")
        var content = objectNamed("panelContent")
        var toolbar = objectNamed("phoneToolbar")
        var unit = objectNamed("interactivePhoneUnit")
        verify(content !== null)
        verify(toolbar !== null)
        verify(unit !== null)
        tryCompare(unit, "x", 0)
        compare(toolbar.width, content.width)


        var settingsActions = objectsNamed("startOverButton")
        var fallbackAction = objectNamed("fallbackStartOverButton")
        compare(settingsActions.length, 1)
        verify(fallbackAction !== null)
        verify(settingsActions[0].visible)
        verify(!fallbackAction.visible)
    }
    function test_trusted_retry_keeps_preview_geometry_and_safety_until_first_frame() {
        var root = panelLoader.item
        var state = objectNamed("pairingState")
        var model = objectNamed("applicationStateModel")
        var toolbar = objectNamed("phoneToolbar")
        var loading = objectNamed("previewLoadingTreatment")
        var panel = objectNamed("boundedKeyboardPanel")
        var reconnect = objectWithText("Reconnect")
        var submapProcess = objectWithProperty("dispatchedSubmap")
        state.reset()
        state.receiveLine(event("ready", {
            sessionGeneration: "0",
            hasTrustedDevice: true,
            scrcpyRevision: "cbf29ce484222325",
            screenOffRequested: false,
            preferences: {
                keepConnected: false,
                previewScale: 100,
                videoQuality: "high",
                quickActions: ["back", "home", "recent-apps"],
                androidModeShortcuts: true
            }
        }))

        tryCompare(model, "captureSurfaceRequired", true)
        verify(panel !== null)
        tryCompare(panel, "contentHeight", panel.availableCardHeight)
        verify(reconnect !== null)
        tryCompare(reconnect, "visible", false)
        verify(submapProcess !== null)
        compare(root.applicationState, "recovering")
        verify(submapProcess.dispatchedSubmap !== "droid-peek")
        var initialGeometry = presentationGeometry()
        compareConnectingPresentation(initialGeometry)

        state.receiveLine(event("connecting", { sessionGeneration: "1" }))
        compareConnectingPresentation(initialGeometry)
        state.receiveLine(event("session-starting", {
            sessionGeneration: "1"
        }))
        compareConnectingPresentation(initialGeometry)
        state.receiveLine(event("session-started", {
            sessionGeneration: "1",
            screenOffEnabled: false
        }))
        compareConnectingPresentation(initialGeometry)

        state.receiveLine(event("session-starting", {
            sessionGeneration: "2"
        }))
        compare(state.sessionGeneration, "2")
        compareConnectingPresentation(initialGeometry)
        state.receiveLine(event("session-started", {
            sessionGeneration: "2",
            screenOffEnabled: false
        }))
        compareConnectingPresentation(initialGeometry)

        tryVerify(function () { return root.phonePreview !== null })
        var preview = root.phonePreview
        preview.videoInputs = [{
            id: preview.deviceId,
            description: preview.deviceDescription
        }]
        tryCompare(preview, "captureRequested", true)
        tryCompare(preview, "deviceAvailable", true)
        var preRefreshEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   preRefreshEpoch, root.acceptedHelperEpoch, "2",
                   preview.deviceId, preview.deviceDescription))
        tryCompare(preview, "captureAvailable", true)
        compare(preview.firstValidFrameReceived, false)
        compare(preview.inputActive, false)
        compare(model.previewUsable, false)
        compare(root.applicationState, "recovering")
        verify(submapProcess.dispatchedSubmap !== "droid-peek")
        compareConnectingPresentation(initialGeometry)

        panelCommandSpy.target = state
        panelCommandSpy.clear()
        verify(!preview.acceptRenderedFrame(
                   preRefreshEpoch, root.acceptedHelperEpoch, "2",
                   1080, 2400, true))
        compare(preview.captureEpoch, preRefreshEpoch)
        compare(panelCommandSpy.count, 0)
        wait(0)

        var captureEpoch = preview.captureEpoch
        compare(captureEpoch, preRefreshEpoch + 1)
        verify(preview.acceptCaptureSource(
                   captureEpoch, root.acceptedHelperEpoch, "2",
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   captureEpoch, root.acceptedHelperEpoch, "2",
                   1080, 2400, true))
        tryCompare(preview, "firstValidFrameReceived", true)
        tryCompare(panelCommandSpy, "count", 1)
        compare(JSON.parse(panelCommandSpy.signalArguments[0][0]), {
            version: 11,
            type: "preview-ready",
            helperEpoch: root.acceptedHelperEpoch,
            sessionGeneration: "2"
        })
        verify(preview.acceptRenderedFrame(
                   captureEpoch, root.acceptedHelperEpoch, "2",
                   1080, 2400, true))
        compare(panelCommandSpy.count, 1)
        tryCompare(model, "previewUsable", true)
        tryCompare(root, "applicationState", "interactive")
        tryCompare(preview, "inputActive", true)
        tryCompare(toolbar, "visible", true)
        tryCompare(loading, "visible", false)
        tryCompare(preview, "framedWidth", 1080)
        tryCompare(preview, "framedHeight", 2400)
        var liveGeometry = presentationGeometry()
        verify(liveGeometry.cardWidth !== initialGeometry.cardWidth
               || liveGeometry.cardHeight !== initialGeometry.cardHeight)
        fuzzyCompare(liveGeometry.cardWidth / liveGeometry.cardHeight,
                     1080 / 2400, 0.01)
        compare(toolbar.width, liveGeometry.cardWidth)
        panelCommandSpy.target = null
    }

    function test_terminal_disconnect_collapses_to_reconnect_presentation() {
        var root = panelLoader.item
        var state = objectNamed("pairingState")
        var model = objectNamed("applicationStateModel")
        var card = objectNamed("previewCard")
        var setupHero = objectNamed("setupHero")
        var title = objectNamed("setupHeadingTitle")
        var reconnect = objectWithText("Reconnect")
        tryCompare(model, "connectionPresentationActive", true)
        var previewGeometry = presentationGeometry()

        state.receiveLine(event("lifecycle-failure", {
            reason: "disconnected",
            sessionGeneration: "2"
        }))

        tryCompare(model, "connectionPresentationActive", false)
        tryCompare(model, "captureSurfaceRequired", false)
        tryCompare(card, "visible", false)
        tryCompare(setupHero, "visible", true)
        tryCompare(title, "text", "Device unavailable")
        verify(reconnect !== null)
        tryCompare(reconnect, "visible", true)
        tryVerify(function () {
            return presentationGeometry().panelHeight < previewGeometry.panelHeight
        })
        compare(root.applicationState, "recovering")
        compare(model.previewUsable, false)
    }

}
