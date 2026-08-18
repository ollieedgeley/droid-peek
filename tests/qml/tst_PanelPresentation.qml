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
        var root = panelLoader.item
        root.settingsOpen = false
        root.managementOpen = false
        var dialog = objectNamed("startOverDialog")
        if (dialog !== null)
            dialog.opened = false
        var model = objectNamed("applicationStateModel")
        model.captureAvailable = false
        model.captureActive = false
        model.firstValidFrameReceived = false
        model.displayWidth = 0
        model.displayHeight = 0
        model.previewInputEnabled = false
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
        var background = objectNamed("previewCardBackground")
        var loading = objectNamed("previewLoadingTreatment")
        var preview = root.phonePreview

        verify(panel !== null)
        verify(content !== null)
        verify(unit !== null)
        verify(toolbar !== null)
        verify(previewCard !== null)
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
        tryCompare(previewCard, "y", 0)
        compare(background.y + background.radius, 0)
        compare(previewCard.height,
                panel.availableCardHeight - panel.verticalContentInset
                - toolbar.implicitHeight - content.spacing)
        tryCompare(content, "implicitHeight", unit.implicitHeight)
        tryCompare(content, "height", content.implicitHeight)

        var loadingCenter = loading.mapToItem(previewCard,
                                              loading.width / 2,
                                              loading.height / 2)
        fuzzyCompare(loadingCenter.x, previewCard.width / 2, 0.5)
        fuzzyCompare(loadingCenter.y, previewCard.height / 2, 0.5)
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

        var settingsActions = objectsNamed("startOverButton")
        var fallbackAction = objectNamed("fallbackStartOverButton")
        compare(settingsActions.length, 1)
        verify(fallbackAction !== null)
        verify(settingsActions[0].visible)
        verify(!fallbackAction.visible)
    }
}
