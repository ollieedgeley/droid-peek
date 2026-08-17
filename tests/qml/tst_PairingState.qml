import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "PairingState"

    PairingState {
        id: state
    }

    SignalSpy {
        id: commandSpy
        target: state
        signalName: "commandRequested"
    }

    SignalSpy {
        id: cancellationSpy
        target: state
        signalName: "pairingCancellationConfirmed"
    }

    SignalSpy {
        id: sessionStopSpy
        target: state
        signalName: "sessionStopConfirmed"
    }

    function init() {
        state.reset()
        commandSpy.clear()
        cancellationSpy.clear()
        sessionStopSpy.clear()
    }

    function event(type, properties) {
        var value = properties || {}
        value.version = 2
        value.type = type
        if (type === "ready" && value.preferences === undefined) {
            value.preferences = {
                previewScale: 100,
                videoQuality: "high",
                quickActions: ["back", "home", "recent-apps"]
            }
        }
        return JSON.stringify(value)
    }

    function test_unpaired_is_the_safe_initial_state() {
        compare(state.sessionState, "unpaired")
        compare(state.pairingStage, "idle")
        verify(state.statusTitle.length > 0)
        compare(state.qrArtifact, "")
        compare(state.qrExpiresInSeconds, 0)
    }

    function test_helper_ready_starts_qr_without_a_connect_action() {
        state.receiveLine(event("ready", { hasTrustedDevice: false }))

        compare(state.helperReady, true)
        compare(commandSpy.count, 1)
        var command = JSON.parse(commandSpy.signalArguments[0][0])
        compare(command.version, 2)
        compare(command.type, "start-qr-pairing")
    }

    function test_helper_ready_reconnects_a_remembered_device() {
        state.receiveLine(event("ready", { hasTrustedDevice: true }))

        compare(state.helperReady, true)
        compare(commandSpy.count, 1)
        compare(JSON.parse(commandSpy.signalArguments[0][0]).type, "reconnect-trusted-device")
    }

    function test_qr_waiting_and_pairing_progress() {
        state.receiveLine(event("qr-waiting", {
            artifact: "/run/user/1000/omarchy-android/qr.svg",
            expiresInSeconds: 120
        }))
        compare(state.sessionState, "qr-waiting")
        compare(state.pairingStage, "qr-waiting")
        compare(state.qrArtifact, "/run/user/1000/omarchy-android/qr.svg")
        compare(state.qrExpiresInSeconds, 120)

        state.receiveLine(event("pairing", { method: "qr" }))
        compare(state.sessionState, "pairing")
        compare(state.pairingStage, "pairing")
    }


    function test_qr_expiry_tick_updates_visible_countdown() {
        state.receiveLine(event("qr-waiting", {
            artifact: "/run/user/1000/omarchy-android/qr.svg",
            expiresInSeconds: 2
        }))

        state.tickQrExpiry()
        compare(state.qrExpiresInSeconds, 1)
        state.tickQrExpiry()
        compare(state.qrExpiresInSeconds, 0)
        state.tickQrExpiry()
        compare(state.qrExpiresInSeconds, 0)
    }
    function test_qr_timeout_requests_a_fresh_code() {
        state.receiveLine(event("qr-timed-out"))

        compare(state.qrArtifact, "")
        compare(state.qrExpiresInSeconds, 0)
        compare(commandSpy.count, 1)
        compare(JSON.parse(commandSpy.signalArguments[0][0]).type, "start-qr-pairing")
    }

    function test_pairing_cancellation_confirms_cleanup() {
        state.receiveLine(event("pairing-cancelled"))

        compare(state.sessionState, "unpaired")
        compare(state.pairingStage, "cancelled")
        compare(cancellationSpy.count, 1)
    }

    function test_manual_code_fallback_never_retains_the_code() {
        state.receiveLine(event("manual-code-required"))
        compare(state.sessionState, "qr-waiting")
        compare(state.pairingStage, "manual-code")

        state.submitManualCode("482913")
        compare(commandSpy.count, 1)
        var command = JSON.parse(commandSpy.signalArguments[0][0])
        compare(command.version, 2)
        compare(command.type, "submit-manual-code")
        compare(command.code, "482913")
        compare(state.statusDescription.indexOf("482913"), -1)
    }

    function test_connected_phone_becomes_ready_only_after_session_starts() {
        state.receiveLine(event("paired"))
        compare(state.sessionState, "pairing")
        compare(state.pairingStage, "connected")

        state.receiveLine(event("session-starting"))
        compare(state.sessionState, "pairing")
        compare(state.pairingStage, "session-starting")

        state.receiveLine(event("session-started", {
                                    physicalWidthMm: 70,
                                    physicalHeightMm: 157
                                }))
        compare(state.sessionState, "ready")
        compare(state.pairingStage, "session-started")
        compare(state.physicalDisplayWidthMm, 70)
        compare(state.physicalDisplayHeightMm, 157)
        compare(state.physicalPreviewSize(3, 1080, 2392, 100),
                Qt.size(210, 471))
        compare(state.physicalPreviewSize(3, 2392, 1080, 150),
                Qt.size(707, 315))

        state.receiveLine(event("session-ended"))
        compare(state.sessionState, "disconnected")
        compare(state.pairingStage, "session-ended")
    }

    function test_reconnect_and_session_stop_are_actionable() {
        state.receiveLine(event("connecting"))
        compare(state.sessionState, "pairing")
        compare(state.pairingStage, "connecting")

        state.receiveLine(event("connected"))
        compare(state.sessionState, "pairing")
        compare(state.pairingStage, "connected")

        state.stopSession()
        compare(JSON.parse(commandSpy.signalArguments[0][0]).type, "stop-session")
        state.receiveLine(event("session-stopped"))
        compare(sessionStopSpy.count, 1)

        state.receiveLine(event("failure", { reason: "disconnected" }))
        compare(state.sessionState, "disconnected")
        state.reconnectTrustedDevice()
        compare(commandSpy.count, 2)
        compare(JSON.parse(commandSpy.signalArguments[1][0]).type, "reconnect-trusted-device")
    }

    function test_commands_are_versioned_line_payloads() {
        state.startQrPairing()
        state.useManualCode()
        state.cancelPairing()
        state.stopSession()

        compare(commandSpy.count, 4)
        compare(JSON.parse(commandSpy.signalArguments[0][0]).type, "start-qr-pairing")
        compare(JSON.parse(commandSpy.signalArguments[1][0]).type, "use-manual-code")
        compare(JSON.parse(commandSpy.signalArguments[2][0]).type, "cancel-pairing")
        compare(JSON.parse(commandSpy.signalArguments[3][0]).type, "stop-session")
        compare(JSON.parse(commandSpy.signalArguments[0][0]).version, 2)
    }

    function test_render_preferences_are_versioned_and_applied_immediately() {
        verify(state.setRenderPreferences(
                   150, "low", ["home", "recent-apps", "back"]))

        compare(state.previewScale, 150)
        compare(state.videoQuality, "low")
        compare(state.quickActions, ["home", "recent-apps", "back"])
        compare(commandSpy.count, 1)
        compare(JSON.parse(commandSpy.signalArguments[0][0]), {
                    version: 2,
                    type: "set-render-preferences",
                    previewScale: 150,
                    videoQuality: "low",
                    quickActions: ["home", "recent-apps", "back"]
                })
    }

    function test_quality_restart_event_waits_for_the_new_session() {
        state.receiveLine(event("session-started"))
        state.receiveLine(event("preferences-updated", {
                                    previewScale: 50,
                                    videoQuality: "medium",
                                    quickActions: ["back", "home", "recent-apps"],
                                    sessionRestarted: true
                                }))

        compare(state.previewScale, 50)
        compare(state.videoQuality, "medium")
        compare(state.sessionState, "pairing")
        compare(state.pairingStage, "session-starting")
        state.receiveLine(event("session-started"))
        compare(state.sessionState, "ready")
    }

    function test_invalid_preferences_fail_closed_without_command() {
        verify(!state.setRenderPreferences(
                   49, "high", ["back", "home", "recent-apps"]))
        verify(!state.setRenderPreferences(
                   151, "high", ["back", "home", "recent-apps"]))
        compare(commandSpy.count, 0)

        state.receiveLine(event("preferences-updated", {
                                    previewScale: 151,
                                    videoQuality: "high",
                                    quickActions: ["back", "home", "recent-apps"],
                                    sessionRestarted: false
                                }))
        compare(state.sessionState, "dependency-unavailable")
        compare(state.pairingStage, "protocol-error")
    }

    function test_failures_and_invalid_events_are_redacted() {
        var rawDetail = "adb pair phone.local:37000 482913 failed"
        state.receiveLine(event("failure", {
            reason: "dependency-unavailable",
            detail: rawDetail
        }))
        compare(state.sessionState, "dependency-unavailable")
        compare(state.statusDescription.indexOf(rawDetail), -1)
        compare(state.statusDescription.indexOf("482913"), -1)

        state.receiveLine(event("failure", {
            reason: "pairing-rejected",
            detail: rawDetail
        }))
        compare(state.sessionState, "unauthorized")
        compare(state.statusTitle, "Pairing rejected")
        compare(state.statusDescription.indexOf(rawDetail), -1)

        state.receiveLine(event("failure", {
            reason: "network-unavailable",
            detail: rawDetail
        }))
        compare(state.sessionState, "disconnected")
        compare(state.statusDescription.indexOf(rawDetail), -1)

        state.receiveLine(event("unknown", { detail: rawDetail }))
        compare(state.sessionState, "dependency-unavailable")
        compare(state.pairingStage, "protocol-error")
        compare(state.statusDescription.indexOf(rawDetail), -1)

        state.receiveLine(JSON.stringify({ version: 9, type: "ready", detail: rawDetail }))
        compare(state.sessionState, "dependency-unavailable")
        compare(state.statusDescription.indexOf(rawDetail), -1)
    }

    function test_input_commands_are_versioned_line_payloads() {
        state.sendPointerTap(0.25, 0.75, 1080, 2400)
        state.sendPointerSwipe(0.1, 0.2, 0.8, 0.9, 1080, 2400, 320)
        state.sendKeyInput("back")
        state.sendTextInput("a")

        compare(commandSpy.count, 4)
        compare(JSON.parse(commandSpy.signalArguments[0][0]), {
                    version: 2,
                    type: "pointer-tap",
                    x: 0.25,
                    y: 0.75,
                    displayWidth: 1080,
                    displayHeight: 2400
                })
        compare(JSON.parse(commandSpy.signalArguments[1][0]).type, "pointer-swipe")
        compare(JSON.parse(commandSpy.signalArguments[1][0]).durationMs, 320)
        compare(JSON.parse(commandSpy.signalArguments[2][0]),
                { version: 2, type: "key-input", key: "back" })
        compare(JSON.parse(commandSpy.signalArguments[3][0]),
                { version: 2, type: "text-input", text: "a" })
    }
}
