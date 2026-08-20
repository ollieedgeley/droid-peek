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

    function findVersionProcess() {
        var seen = []
        var pending = [panelLoader.item]
        while (pending.length > 0) {
            var object = pending.pop()
            if (!object || seen.indexOf(object) !== -1)
                continue
            seen.push(object)
            if (object.command && object.command.indexOf("--version") >= 0)
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

    function event(type, values) {
        var result = values || {}
        result.version = 11
        result.type = type
        result.helperEpoch = panelLoader.item.acceptedHelperEpoch
        return JSON.stringify(result)
    }

    function lastCommand(helper) {
        var lines = helper.writtenLines
        if (lines.length === 0)
            return null
        return JSON.parse(lines[lines.length - 1])
    }

    function ensureHelperRunning() {
        var versionProcess = findVersionProcess()
        if (versionProcess) {
            versionProcess.versionReply = "1.0.0"
            versionProcess.versionExitCode = 0
            versionProcess.autoCompleteVersion = true
        }
        var panel = panelLoader.item
        if (!panel.opened)
            panel.open()
        var helper = findHelperProcess(panel)
        if (helper !== null && !helper.running)
            panel.launchHelper()
        tryVerify(function () {
            return panel.acceptedHelperEpoch !== ""
        })
        tryCompare(helper, "running", true)
        return helper
    }

    function stopHelper() {
        var panel = panelLoader.item
        var helper = findHelperProcess(panel)
        var epoch = panel.acceptedHelperEpoch
        panel.close()
        compare(panel.opened, false)
        if (helper.running && epoch !== "") {
            helper.stdout.read(JSON.stringify({
                version: 11,
                type: "pairing-cancelled",
                helperEpoch: epoch
            }))
        }
        tryCompare(helper, "running", false)
        compare(panel.acceptedHelperEpoch, "")
        return helper
    }

    function beginRetainedSession() {
        var panel = panelLoader.item
        var state = objectNamed("pairingState")
        var helper = findHelperProcess(panel)
        helper.stdout.read(JSON.stringify({
            version: 11,
            type: "ready",
            helperEpoch: panel.acceptedHelperEpoch,
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
        helper.stdout.read(event("connected", {
                                     sessionGeneration: "1"
                                 }))
        helper.stdout.read(event("session-started", {
                                     sessionGeneration: "1",
                                     screenOffEnabled: false
                                 }))
        compare(state.sessionStarted, true)
        compare(state.keepConnected, true)
        compare(panel.helperCloseAction(), "retain")
        return helper
    }

    function init() {
        compare(panelLoader.status, Loader.Ready)
        ensureHelperRunning()
        var state = objectNamed("pairingState")
        verify(state !== null)
        state.keepConnected = false
        state.reset()
        var helper = findHelperProcess(panelLoader.item)
        if (helper)
            helper.written = ""
    }

    function cleanup() {
        var state = objectNamed("pairingState")
        if (state !== null) {
            state.keepConnected = false
            state.reset()
        }
        ensureHelperRunning()
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

    function test_manual_code_submit_success() {
        var panel = panelLoader.item
        var helper = findHelperProcess(panel)
        var state = objectNamed("pairingState")
        helper.stdout.read(readyLine(panel.acceptedHelperEpoch))
        helper.stdout.read(event("manual-code-required"))
        compare(state.pairingStage, "manual-code")

        var field = objectNamed("manualCodeField")
        var pairButton = objectNamed("pairButton")
        verify(field !== null)
        verify(pairButton !== null)
        tryCompare(field, "visible", true)
        tryCompare(pairButton, "visible", true)
        helper.written = ""

        field.text = "123456"
        pairButton.clicked()
        compare(helper.writtenLines.length, 1)
        compare(lastCommand(helper), {
                    version: 11,
                    type: "submit-manual-code",
                    helperEpoch: panel.acceptedHelperEpoch,
                    code: "123456"
                })
        compare(field.text, "")

        helper.stdout.read(event("connected", {
                                     sessionGeneration: "1"
                                 }))
        compare(state.pairingStage, "connected")
        compare(state.hasTrustedDevice, true)
        compare(helper.writtenLines.length, 1)
        compare(helper.running, true)
    }

    function test_manual_code_submit_rejection() {
        var panel = panelLoader.item
        var helper = findHelperProcess(panel)
        var state = objectNamed("pairingState")
        helper.stdout.read(readyLine(panel.acceptedHelperEpoch))
        helper.stdout.read(event("manual-code-required"))

        var field = objectNamed("manualCodeField")
        var pairButton = objectNamed("pairButton")
        helper.written = ""
        field.text = "654321"
        pairButton.clicked()
        compare(lastCommand(helper), {
                    version: 11,
                    type: "submit-manual-code",
                    helperEpoch: panel.acceptedHelperEpoch,
                    code: "654321"
                })

        helper.stdout.read(event("failure", {
                                     reason: "pairing-rejected"
                                 }))
        compare(state.pairingStage, "failed")
        compare(state.statusTitle, "Pairing rejected")
        compare(state.statusDescription,
                "Check the pairing code or generate a fresh QR code, then retry.")
        compare(helper.writtenLines.length, 1)
        compare(helper.running, true)
    }

    function test_invalid_manual_code_is_not_submitted() {
        var panel = panelLoader.item
        var helper = findHelperProcess(panel)
        var state = objectNamed("pairingState")
        helper.stdout.read(readyLine(panel.acceptedHelperEpoch))
        helper.stdout.read(event("manual-code-required"))

        var field = objectNamed("manualCodeField")
        var pairButton = objectNamed("pairButton")
        helper.written = ""
        field.text = "12345"
        pairButton.clicked()

        compare(helper.writtenLines.length, 0)
        compare(state.statusDescription,
                "Enter the six-digit pairing code shown by Android.")
        compare(field.text, "12345")
    }

    function test_qr_timeout_requests_fresh_qr() {
        var panel = panelLoader.item
        var helper = findHelperProcess(panel)
        var state = objectNamed("pairingState")
        helper.stdout.read(readyLine(panel.acceptedHelperEpoch))
        helper.stdout.read(event("qr-waiting", {
                                     artifact: "/tmp/droid-peek-test-qr.png",
                                     expiresInSeconds: 2
                                 }))
        compare(state.pairingStage, "qr-waiting")
        helper.written = ""

        helper.stdout.read(event("qr-timed-out"))

        compare(state.pairingStage, "starting")
        compare(helper.writtenLines.length, 1)
        compare(lastCommand(helper), {
                    version: 11,
                    type: "start-qr-pairing",
                    helperEpoch: panel.acceptedHelperEpoch
                })
        compare(helper.running, true)
    }

    function test_close_during_qr_cancels_then_stops_helper() {
        var panel = panelLoader.item
        var helper = findHelperProcess(panel)
        var state = objectNamed("pairingState")
        helper.stdout.read(readyLine(panel.acceptedHelperEpoch))
        helper.stdout.read(event("qr-waiting", {
                                     artifact: "/tmp/droid-peek-test-qr.png",
                                     expiresInSeconds: 30
                                 }))
        var epoch = panel.acceptedHelperEpoch
        helper.written = ""

        panel.close()

        compare(panel.opened, false)
        compare(helper.running, true)
        compare(panel.acceptedHelperEpoch, epoch)
        compare(helper.writtenLines.length, 1)
        compare(lastCommand(helper), {
                    version: 11,
                    type: "cancel-pairing",
                    helperEpoch: epoch
                })

        helper.stdout.read(event("pairing-cancelled"))

        tryCompare(helper, "running", false)
        compare(panel.acceptedHelperEpoch, "")
    }

    function test_helper_version_mismatch_does_not_start_helper() {
        var panel = panelLoader.item
        var state = objectNamed("pairingState")
        var helper = stopHelper()
        var versionProcess = findVersionProcess()
        verify(versionProcess !== null)
        var helperStarts = helper.startCount
        var versionStarts = versionProcess.startCount
        versionProcess.versionReply = "0.0.0"

        panel.open()

        compare(panel.opened, true)
        tryCompare(state, "pairingStage", "protocol-error")
        compare(state.statusTitle, "Android helper unavailable")
        compare(state.helperReady, false)
        compare(versionProcess.startCount, versionStarts + 1)
        compare(helper.startCount, helperStarts)
        compare(helper.running, false)
        compare(panel.acceptedHelperEpoch, "")
    }

    function test_helper_exit_during_open_setup_relaunches() {
        var panel = panelLoader.item
        var helper = findHelperProcess(panel)
        var versionProcess = findVersionProcess()
        var epoch = panel.acceptedHelperEpoch
        var helperStarts = helper.startCount
        var versionStarts = versionProcess.startCount
        compare(panel.opened, true)
        compare(helper.running, true)

        helper.exitProcess(17)

        tryCompare(helper, "startCount", helperStarts + 1)
        tryCompare(versionProcess, "startCount", versionStarts + 1)
        tryVerify(function () {
            return panel.acceptedHelperEpoch !== ""
                    && panel.acceptedHelperEpoch !== epoch
        })
        compare(helper.running, true)
        verify(helper.command.indexOf(panel.acceptedHelperEpoch) >= 0)
    }

    function test_helper_exit_during_open_live_session_relaunches() {
        var panel = panelLoader.item
        var state = objectNamed("pairingState")
        var helper = beginRetainedSession()
        var versionProcess = findVersionProcess()
        var epoch = panel.acceptedHelperEpoch
        var helperStarts = helper.startCount
        var versionStarts = versionProcess.startCount
        compare(state.sessionStarted, true)

        helper.exitProcess(23)

        tryCompare(helper, "startCount", helperStarts + 1)
        tryCompare(versionProcess, "startCount", versionStarts + 1)
        tryVerify(function () {
            return panel.acceptedHelperEpoch !== ""
                    && panel.acceptedHelperEpoch !== epoch
        })
        compare(helper.running, true)
        compare(state.helperReady, false)
        compare(state.sessionStarted, false)
    }

    function test_helper_exit_while_retained_closed_does_not_relaunch() {
        var panel = panelLoader.item
        var helper = beginRetainedSession()
        var versionProcess = findVersionProcess()
        var epoch = panel.acceptedHelperEpoch
        var helperStarts = helper.startCount
        var versionStarts = versionProcess.startCount

        panel.close()
        compare(panel.opened, false)
        compare(helper.running, true)
        compare(panel.acceptedHelperEpoch, epoch)

        helper.exitProcess(29)
        wait(50)

        compare(helper.startCount, helperStarts)
        compare(versionProcess.startCount, versionStarts)
        compare(helper.running, false)
        compare(panel.opened, false)
        compare(panel.acceptedHelperEpoch, "")
    }
}
