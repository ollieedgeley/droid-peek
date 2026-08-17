import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "PairingState"
    property var androidModeShortcutsAtCommand: undefined


    PairingState {
        id: state
    }

    SignalSpy {
        id: commandSpy
        target: state
        signalName: "commandRequested"
    }
    Connections {
        target: state

        function onCommandRequested() {
            androidModeShortcutsAtCommand = state.androidModeShortcuts
        }
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

    SignalSpy {
        id: actionCompletedSpy
        target: state
        signalName: "semanticActionCompleted"
    }

    function init() {
        state.reset()
        androidModeShortcutsAtCommand = undefined
        commandSpy.clear()
        cancellationSpy.clear()
        sessionStopSpy.clear()
        actionCompletedSpy.clear()
    }

    function preferences(androidModeShortcuts) {
        return {
            keepConnected: false,
            previewScale: 100,
            videoQuality: "high",
            quickActions: ["back", "home", "recent-apps"],
            androidModeShortcuts: androidModeShortcuts
        }
    }

    function event(type, properties) {
        var value = properties || {}
        value.version = state.protocolVersion
        value.type = type
        if (type === "ready" && value.preferences === undefined) {
            value.preferences = preferences(false)
        }
        return JSON.stringify(value)
    }

    function test_unpaired_is_the_safe_initial_state() {
        compare(state.protocolVersion, 8)
        compare(state.sessionState, "unpaired")
        compare(state.pairingStage, "idle")
        verify(state.statusTitle.length > 0)
        compare(state.qrArtifact, "")
        compare(state.qrExpiresInSeconds, 0)
        compare(state.androidModeShortcuts, false)
    }

    function test_helper_ready_starts_qr_without_a_connect_action() {
        state.receiveLine(event("ready", { hasTrustedDevice: false }))

        compare(state.helperReady, true)
        compare(commandSpy.count, 1)
        var command = JSON.parse(commandSpy.signalArguments[0][0])
        compare(command.version, 8)
        compare(command.type, "start-qr-pairing")
    }

    function test_helper_ready_reconnects_a_remembered_device() {
        state.receiveLine(event("ready", {
                                    hasTrustedDevice: true,
                                    preferences: preferences(true)
                                }))

        compare(state.helperReady, true)
        compare(state.androidModeShortcuts, true)
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
        compare(command.version, 8)
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
    function test_semantic_action_commands_and_results_are_correlated() {
        var expiresAtUnixMs = Date.now() + 2000
        verify(state.sendSemanticAction(
                   "omarchy-browser", "request-123", expiresAtUnixMs))

        compare(commandSpy.count, 1)
        var command = JSON.parse(commandSpy.signalArguments[0][0])
        compare(command.version, state.protocolVersion)
        compare(command.type, "semantic-action")
        compare(command.actionId, "omarchy-browser")
        compare(command.requestId, "request-123")
        compare(command.expiresAtUnixMs, expiresAtUnixMs)

        state.receiveLine(event("action-result", {
                                    actionId: "omarchy-browser",
                                    requestId: "request-123",
                                    handled: true
                                }))
        compare(actionCompletedSpy.count, 1)
        compare(actionCompletedSpy.signalArguments[0][0], "omarchy-browser")
        compare(actionCompletedSpy.signalArguments[0][1], "request-123")
        compare(actionCompletedSpy.signalArguments[0][2], true)
    }

    function test_semantic_actions_reject_invalid_deadlines_before_emitting_commands() {
        verify(!state.sendSemanticAction(
                   "omarchy-browser", "request-missing"))
        verify(!state.sendSemanticAction(
                   "omarchy-browser", "request-string", String(Date.now() + 2000)))
        verify(!state.sendSemanticAction(
                   "omarchy-browser", "request-fraction", Date.now() + 2000.5))
        verify(!state.sendSemanticAction(
                   "omarchy-browser", "request-expired", Date.now() - 1))
        verify(!state.sendSemanticAction(
                   "omarchy-browser", "request-invalid", NaN))
        compare(commandSpy.count, 0)
    }

    function test_start_over_forgets_the_device_then_requests_fresh_qr() {
        state.receiveLine(event("ready", { hasTrustedDevice: true }))
        state.setPreferences(
                    true, 125, "medium", ["home", "back", "recent-apps"], true)
        commandSpy.clear()

        state.startOver()
        state.startOver()

        compare(state.startOverPending, true)
        compare(state.statusTitle, "Starting over")
        compare(commandSpy.count, 1)
        compare(JSON.parse(commandSpy.signalArguments[0][0]),
                { version: 8, type: "start-over" })

        state.receiveLine(event("start-over-complete"))

        compare(state.startOverPending, false)
        compare(state.hasTrustedDevice, false)
        compare(state.sessionState, "unpaired")
        compare(state.keepConnected, true)
        compare(state.previewScale, 125)
        compare(state.videoQuality, "medium")
        compare(state.androidModeShortcuts, true)
        compare(commandSpy.count, 2)
        compare(JSON.parse(commandSpy.signalArguments[1][0]).type,
                "start-qr-pairing")
    }

    function test_start_over_failure_keeps_the_phone_and_does_not_request_qr() {
        state.receiveLine(event("ready", { hasTrustedDevice: true }))
        commandSpy.clear()

        state.startOver()
        state.receiveLine(event("failure", { reason: "dependency-unavailable" }))

        compare(state.startOverPending, false)
        compare(state.hasTrustedDevice, true)
        compare(state.pairingStage, "start-over-failed")
        compare(state.statusTitle, "Couldn’t start over")
        compare(commandSpy.count, 1)
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
        compare(JSON.parse(commandSpy.signalArguments[0][0]).version, 8)
    }

    function test_preferences_are_versioned_and_applied_immediately() {
        verify(state.setPreferences(
                   true, 150, "low", ["home", "recent-apps", "back"], true))

        compare(state.keepConnected, true)
        compare(state.previewScale, 150)
        compare(state.videoQuality, "low")
        compare(state.quickActions, ["home", "recent-apps", "back"])
        compare(state.androidModeShortcuts, true)
        compare(androidModeShortcutsAtCommand, true)
        compare(commandSpy.count, 1)
        compare(JSON.parse(commandSpy.signalArguments[0][0]), {
                    version: 8,
                    type: "set-preferences",
                    keepConnected: true,
                    previewScale: 150,
                    videoQuality: "low",
                    quickActions: ["home", "recent-apps", "back"],
                    androidModeShortcuts: true
                })
    }

    function test_quality_restart_event_waits_for_the_new_session() {
        state.receiveLine(event("session-started"))
        state.receiveLine(event("preferences-updated", {
                                    keepConnected: true,
                                    previewScale: 50,
                                    videoQuality: "medium",
                                    quickActions: ["back", "home", "recent-apps"],
                                    androidModeShortcuts: true,
                                    sessionRestarted: true
                                }))

        compare(state.previewScale, 50)
        compare(state.keepConnected, true)
        compare(state.videoQuality, "medium")
        compare(state.androidModeShortcuts, true)
        compare(state.sessionState, "pairing")
        compare(state.pairingStage, "session-starting")
        state.receiveLine(event("session-started"))
        compare(state.sessionState, "ready")
    }

    function test_preferences_update_rejects_invalid_session_restarted_atomically_data() {
        return [
            {
                tag: "missing"
            },
            {
                tag: "non-boolean",
                sessionRestarted: "true"
            }
        ]
    }

    function test_preferences_update_rejects_invalid_session_restarted_atomically(data) {
        state.receiveLine(event("session-started"))
        compare(state.sessionState, "ready")
        compare(state.androidModeShortcuts, false)

        var payload = {
            keepConnected: true,
            previewScale: 150,
            videoQuality: "low",
            quickActions: ["home", "recent-apps", "back"],
            androidModeShortcuts: true
        }
        if (data.sessionRestarted !== undefined)
            payload.sessionRestarted = data.sessionRestarted

        state.receiveLine(event("preferences-updated", payload))

        compare(state.sessionState, "dependency-unavailable")
        compare(state.pairingStage, "protocol-error")
        compare(state.keepConnected, false)
        compare(state.previewScale, 100)
        compare(state.videoQuality, "high")
        compare(state.quickActions, ["back", "home", "recent-apps"])
        compare(state.androidModeShortcuts, false)

        state.receiveLine(event("session-started"))

        compare(state.sessionState, "ready")
        compare(state.androidModeShortcuts, false)
    }

    function test_invalid_preferences_fail_closed_without_command() {
        verify(!state.setPreferences(
                   false, 49, "high", ["back", "home", "recent-apps"], false))
        verify(!state.setPreferences(
                   false, 151, "high", ["back", "home", "recent-apps"], false))
        compare(commandSpy.count, 0)

        state.receiveLine(event("preferences-updated", {
                                    keepConnected: false,
                                    previewScale: 151,
                                    videoQuality: "high",
                                    quickActions: ["back", "home", "recent-apps"],
                                    androidModeShortcuts: false,
                                    sessionRestarted: false
                                }))
        compare(state.sessionState, "dependency-unavailable")
        compare(state.pairingStage, "protocol-error")
    }

    function test_set_preferences_requires_boolean_android_mode_shortcuts() {
        verify(!state.setPreferences(
                   true, 125, "medium", ["home", "back", "recent-apps"]))
        verify(!state.setPreferences(
                   true, 125, "medium", ["home", "back", "recent-apps"], "true"))

        compare(state.keepConnected, false)
        compare(state.previewScale, 100)
        compare(state.videoQuality, "high")
        compare(state.quickActions, ["back", "home", "recent-apps"])
        compare(state.androidModeShortcuts, false)
        compare(commandSpy.count, 0)
    }

    function test_ready_and_preference_updates_require_android_mode_shortcuts_data() {
        return [
            {
                tag: "ready missing",
                type: "ready",
                payload: {
                    hasTrustedDevice: false,
                    preferences: {
                        keepConnected: false,
                        previewScale: 100,
                        videoQuality: "high",
                        quickActions: ["back", "home", "recent-apps"]
                    }
                }
            },
            {
                tag: "ready non-bool",
                type: "ready",
                payload: {
                    hasTrustedDevice: false,
                    preferences: {
                        keepConnected: false,
                        previewScale: 100,
                        videoQuality: "high",
                        quickActions: ["back", "home", "recent-apps"],
                        androidModeShortcuts: "false"
                    }
                }
            },
            {
                tag: "preferences-updated missing",
                type: "preferences-updated",
                payload: {
                    keepConnected: false,
                    previewScale: 100,
                    videoQuality: "high",
                    quickActions: ["back", "home", "recent-apps"],
                    sessionRestarted: false
                }
            },
            {
                tag: "preferences-updated non-bool",
                type: "preferences-updated",
                payload: {
                    keepConnected: false,
                    previewScale: 100,
                    videoQuality: "high",
                    quickActions: ["back", "home", "recent-apps"],
                    androidModeShortcuts: 0,
                    sessionRestarted: false
                }
            }
        ]
    }

    function test_ready_and_preference_updates_require_android_mode_shortcuts(data) {
        state.receiveLine(event(data.type, data.payload))

        compare(state.helperReady, false)
        compare(state.androidModeShortcuts, false)
        compare(state.sessionState, "dependency-unavailable")
        compare(state.pairingStage, "protocol-error")
        compare(commandSpy.count, 0)
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
                    version: 8,
                    type: "pointer-tap",
                    x: 0.25,
                    y: 0.75,
                    displayWidth: 1080,
                    displayHeight: 2400
                })
        compare(JSON.parse(commandSpy.signalArguments[1][0]).type, "pointer-swipe")
        compare(JSON.parse(commandSpy.signalArguments[1][0]).durationMs, 320)
        compare(JSON.parse(commandSpy.signalArguments[2][0]),
                { version: 8, type: "key-input", key: "back" })
        compare(JSON.parse(commandSpy.signalArguments[3][0]),
                { version: 8, type: "text-input", text: "a" })
    }
}
