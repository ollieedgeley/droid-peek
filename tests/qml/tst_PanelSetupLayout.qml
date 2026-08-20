import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "PanelSetupLayout"
    when: windowShown
    visible: true
    width: acceptanceOutputWidth
    height: acceptanceOutputHeight

    readonly property real acceptanceOutputWidth: 1440
    readonly property real acceptanceOutputHeight: 900
    readonly property real acceptanceDisplayScale: 2
    readonly property real acceptedQrLogicalSize: 180
    readonly property url qrFixtureUrl: Qt.resolvedUrl(
                                             "fixtures/qr-placeholder.svg")
    readonly property string qrFixturePath: String(qrFixtureUrl).replace(
                                                "file://", "")

    Item {
        id: anchorItem
        width: outputWidth / outputScale
        height: outputHeight / outputScale

        property real outputWidth: testCase.acceptanceOutputWidth
        property real outputHeight: testCase.acceptanceOutputHeight
        property real outputScale: testCase.acceptanceDisplayScale
    }

    QtObject {
        id: topBar
        property string position: "top"
        property real barSize: 26
        property color barForeground: "white"
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

    function setupPairingState() {
        var state = objectNamed("pairingState")
        verify(state !== null)
        state.reset()
        state.receiveLine(JSON.stringify({
            version: 11,
            type: "ready",
            helperEpoch: panelLoader.item.acceptedHelperEpoch,
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
        }))
        state.receiveLine(JSON.stringify({
            version: 11,
            type: "qr-waiting",
            helperEpoch: panelLoader.item.acceptedHelperEpoch,
            artifact: testCase.qrFixturePath,
            expiresInSeconds: 120
        }))
        return state
    }

    function waitForSetupLayout() {
        var root = panelLoader.item
        var panel = objectNamed("boundedKeyboardPanel")
        var content = objectNamed("panelContent")
        var state = objectNamed("pairingState")
        var hero = objectNamed("setupHero")
        var description = objectNamed("setupDescription")
        var expiry = objectNamed("qrExpiry")
        var actions = objectNamed("pairingActions")
        var field = objectNamed("manualCodeField")
        tryVerify(function () {
            var expectedImplicitHeight
            if (state.pairingStage === "qr-waiting") {
                expectedImplicitHeight = hero.implicitHeight
                        + description.implicitHeight + root.setupQrSize
                        + expiry.implicitHeight + actions.implicitHeight
                        + root.setupSpacing * 4
            } else {
                expectedImplicitHeight = hero.implicitHeight
                        + description.implicitHeight + field.implicitHeight
                        + actions.implicitHeight + root.setupSpacing * 3
            }
            return Math.abs(content.implicitHeight
                            - expectedImplicitHeight) < 0.5
                    && panel.contentHeight
                       === panel.fittedContentHeight(content.implicitHeight)
        }, 1000, "The setup column and fitted panel height did not converge")
    }

    function assertInsidePanel(item, description) {
        var panel = objectNamed("boundedKeyboardPanel")
        verify(panel !== null)
        verify(item.width > 0 && item.height > 0,
               description + " must have nonzero geometry")
        var origin = item.mapToItem(panel, 0, 0)
        var bounds = panel.contentBounds
        verify(origin.x >= bounds.x,
               description + " starts left of the popup content")
        verify(origin.y >= bounds.y,
               description + " starts above the popup content")
        verify(origin.x + item.width <= bounds.x + bounds.width,
               description + " extends past the popup's right edge")
        verify(origin.y + item.height <= bounds.y + bounds.height,
               description + " extends below the popup's visible bounds")
    }

    function focusPanel() {
        var panel = objectNamed("boundedKeyboardPanel")
        verify(panel !== null)
        panel.focusTarget.forceActiveFocus()
        compare(panel.focusTarget.activeFocus, true)
    }

    function init() {
        compare(panelLoader.status, Loader.Ready)
        panelLoader.item.open()
        compare(panelLoader.item.opened, true)
        tryVerify(function () {
            return panelLoader.item.acceptedHelperEpoch !== ""
        })
        setupPairingState()
        waitForSetupLayout()

        var panel = objectNamed("boundedKeyboardPanel")
        var content = objectNamed("panelContent")
        verify(panel !== null)
        verify(content !== null)
        compare(panel.open, true)
        compare(panel.visible, true)
        verify(panel.contentBounds.width > 0)
        verify(panel.contentBounds.height > 0)
        compare(panel.contentHeight,
                panel.fittedContentHeight(content.implicitHeight))
        compare(panel.contentBounds.height,
                panel.contentHeight - panel.verticalContentInset)
    }

    function test_setup_heading_is_flush_and_retains_all_labels() {
        var content = objectNamed("panelContent")
        var heading = objectNamed("setupHero")
        var title = objectNamed("setupHeadingTitle")
        var tag = objectNamed("setupHeadingTag")
        var meta = objectNamed("setupHeadingMeta")
        var description = objectNamed("setupDescription")

        verify(content !== null)
        verify(heading !== null)
        verify(title !== null)
        verify(tag !== null)
        verify(meta !== null)
        verify(description !== null)
        compare(title.text, "Scan with your Android device")
        compare(tag.text, "unpaired")
        compare(meta.text, "DROID PEEK")

        var contentOrigin = content.mapToItem(testCase, 0, 0)
        var titleOrigin = title.mapToItem(testCase, 0, 0)
        var metaOrigin = meta.mapToItem(testCase, 0, 0)
        var descriptionOrigin = description.mapToItem(testCase, 0, 0)
        compare(titleOrigin.x, contentOrigin.x)
        compare(metaOrigin.x, contentOrigin.x)
        compare(descriptionOrigin.x, contentOrigin.x)
    }

    function test_dependency_unavailable_changes_only_the_compact_tag() {
        var state = objectNamed("pairingState")
        state.localIntegrationFailure()

        compare(state.sessionState, "dependency-unavailable")
        compare(state.statusTitle, "Android keyboard shortcuts unavailable")
        compare(state.statusDescription,
                "Desktop Android shortcuts could not be activated. The device connection may still be retained.")

        var title = objectNamed("setupHeadingTitle")
        var tag = objectNamed("setupHeadingTag")
        var description = objectNamed("setupDescription")
        tryCompare(tag, "text", "Shortcuts")
        compare(title.text, state.statusTitle)
        compare(description.text, state.statusDescription)
        verify(description.visible)
    }

    function test_qr_waiting_is_scannable_bounded_and_keyboard_reachable() {
        var state = objectNamed("pairingState")
        compare(state.pairingStage, "qr-waiting")
        compare(state.sessionState, "unpaired")

        var qr = objectNamed("pairingQr")
        verify(qr !== null)
        verify(qr.visible)
        compare(qr.width, qr.height)
        verify(qr.width >= acceptedQrLogicalSize)
        assertInsidePanel(qr, "QR")

        var pairByCode = objectNamed("pairByCodeButton")
        verify(pairByCode !== null)
        verify(pairByCode.visible)
        assertInsidePanel(pairByCode, "Pair by code")
        focusPanel()
        keyClick(Qt.Key_Tab)
        tryCompare(pairByCode, "activeFocus", true)
    }

    function test_manual_code_event_keeps_actions_bounded_and_keyboard_reachable() {
        var state = objectNamed("pairingState")
        var pairByCode = objectNamed("pairByCodeButton")
        pairByCode.clicked()
        state.receiveLine(JSON.stringify({
            version: 11,
            type: "manual-code-required",
            helperEpoch: panelLoader.item.acceptedHelperEpoch
        }))
        waitForSetupLayout()

        compare(state.pairingStage, "manual-code")

        var codeField = objectNamed("manualCodeField")
        verify(codeField !== null)
        verify(codeField.visible)
        compare(codeField.maximumLength, 6)
        assertInsidePanel(codeField, "Six-digit field")

        var pairAction = objectNamed("pairButton")
        verify(pairAction !== null)
        verify(pairAction.visible)
        assertInsidePanel(pairAction, "Pair")

        focusPanel()
        keyClick(Qt.Key_Tab)
        tryCompare(codeField, "activeFocus", true)
        keyClick(Qt.Key_Tab)
        tryCompare(pairAction, "activeFocus", true)
    }
}
