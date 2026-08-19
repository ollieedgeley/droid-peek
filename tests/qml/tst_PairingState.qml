import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "PairingState"

    PairingState {
        id: state
        helperEpoch: "17"
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

    SignalSpy {
        id: phoneTargetCompletedSpy
        target: state
        signalName: "phoneTargetCompleted"
    }

    SignalSpy {
        id: preferenceFailureSpy
        target: state
        signalName: "preferenceUpdateFailed"
    }

    function defaultPreferences(androidModeShortcuts) {
        return {
            keepConnected: false,
            previewScale: 100,
            videoQuality: "high",
            quickActions: ["back", "home", "recent-apps"],
            androidModeShortcuts: androidModeShortcuts === undefined
                                      ? true : androidModeShortcuts
        }
    }

    function event(type, properties, epoch) {
        var value = properties || {}
        value.version = 11
        value.type = type
        value.helperEpoch = epoch === undefined ? state.helperEpoch : epoch
        if (type === "ready") {
            if (value.sessionGeneration === undefined)
                value.sessionGeneration = "0"
            if (value.preferences === undefined)
                value.preferences = defaultPreferences()
            if (value.scrcpyRevision === undefined)
                value.scrcpyRevision = "cbf29ce484222325"
            if (value.screenOffRequested === undefined)
                value.screenOffRequested = false
        }
        if (type === "session-started" && value.screenOffEnabled === undefined)
            value.screenOffEnabled = false
        return JSON.stringify(value)
    }

    function commandAt(index) {
        return JSON.parse(commandSpy.signalArguments[index][0])
    }

    function init() {
        state.reset()
        state.hasTrustedDevice = false
        state.helperEpoch = "17"
        state.previewSurfaceMounted = false
        commandSpy.clear()
        cancellationSpy.clear()
        phoneTargetCompletedSpy.clear()
        preferenceFailureSpy.clear()
        sessionStopSpy.clear()
    }

    function establishTrustedBaseline() {
        state.receiveLine(event("ready", {
            hasTrustedDevice: true,
            sessionGeneration: "0"
        }))
        commandSpy.clear()
    }

    function establishLiveSession() {
        establishTrustedBaseline()
        state.receiveLine(event("connecting", { sessionGeneration: "1" }))
        state.receiveLine(event("connected", { sessionGeneration: "1" }))
        state.receiveLine(event("session-starting", { sessionGeneration: "1" }))
        state.receiveLine(event("session-started", {
            sessionGeneration: "1",
            physicalWidthMm: 70,
            physicalHeightMm: 157
        }))
    }

    function test_protocol_v11_baseline_and_defaults() {
        compare(state.protocolVersion, 11)
        compare(state.androidModeShortcuts, true)
        compare(state.commandPassthrough, undefined)

        state.receiveLine(event("ready", { hasTrustedDevice: false }))

        compare(state.helperReady, true)
        compare(state.hasTrustedDevice, false)
        compare(state.sessionGeneration, "0")
        compare(commandSpy.count, 1)
        compare(commandAt(0), {
            version: 11,
            type: "start-qr-pairing",
            helperEpoch: "17"
        })
    }

    function test_ready_with_trusted_phone_requests_reconnect_in_current_epoch() {
        state.receiveLine(event("ready", { hasTrustedDevice: true }))

        compare(state.hasTrustedDevice, true)
        compare(commandSpy.count, 1)
        compare(commandAt(0), {
            version: 11,
            type: "reconnect-trusted-device",
            helperEpoch: "17"
        })
    }

    function test_pairing_only_events_are_admitted_by_epoch_without_generation() {
        state.receiveLine(event("ready", { hasTrustedDevice: false }))
        commandSpy.clear()

        state.receiveLine(event("qr-waiting", {
            artifact: "/run/user/1000/droid-peek/qr.svg",
            expiresInSeconds: 120
        }))
        compare(state.activity, "qr-waiting")
        state.receiveLine(event("qr-timed-out"))
        compare(state.activity, "starting-pairing")
        compare(commandSpy.count, 1)
        compare(commandAt(0).type, "start-qr-pairing")
        commandSpy.clear()


        state.receiveLine(event("pairing", { method: "qr" }))
        compare(state.activity, "pairing")

        state.receiveLine(event("manual-code-required"))
        compare(state.activity, "manual-code")

        state.receiveLine(event("pairing-cancelled"))
        compare(state.activity, "pairing-cancelled")
        compare(cancellationSpy.count, 1)

        state.receiveLine(event("failure", { reason: "pairing-rejected" }))
        compare(state.hasTrustedDevice, false)
        compare(state.reason, "pairing-rejected")
    }

    function test_session_event_sequence_advances_then_reuses_generation() {
        establishTrustedBaseline()
        state.receiveLine(event("paired", { sessionGeneration: "1" }))
        compare(state.sessionGeneration, "1")
        compare(state.hasTrustedDevice, true)
        compare(state.activity, "connecting")


        state.receiveLine(event("connecting", { sessionGeneration: "1" }))
        compare(state.sessionGeneration, "1")
        compare(state.activity, "connecting")
        compare(state.sessionStarted, false)

        state.receiveLine(event("connected", { sessionGeneration: "1" }))
        compare(state.activity, "connected")

        state.receiveLine(event("session-starting", { sessionGeneration: "1" }))
        compare(state.activity, "starting-preview")

        state.receiveLine(event("session-started", { sessionGeneration: "1" }))
        compare(state.sessionStarted, true)
        compare(state.activity, "")
    }

    function test_session_end_stop_and_lifecycle_failure_invalidate_the_session() {
        establishLiveSession()

        state.receiveLine(event("session-ended", { sessionGeneration: "2" }))
        compare(state.sessionGeneration, "2")
        compare(state.sessionStarted, false)
        compare(state.reason, "disconnected")

        state.receiveLine(event("session-stopped", { sessionGeneration: "2" }))
        compare(state.sessionGeneration, "2")
        compare(state.pairingStage, "session-stopped")
        compare(sessionStopSpy.count, 1)

        state.receiveLine(event("lifecycle-failure", {
            reason: "network-unavailable",
            sessionGeneration: "3"
        }))
        compare(state.sessionGeneration, "3")
        compare(state.sessionStarted, false)
        compare(state.reason, "network-unavailable")
    }

    function test_start_over_and_restart_events_accept_the_new_generation() {
        establishLiveSession()

        state.receiveLine(event("preferences-updated", {
            keepConnected: true,
            previewScale: 125,
            videoQuality: "medium",
            quickActions: ["home", "back", "recent-apps"],
            androidModeShortcuts: false,
            sessionRestarted: true,
            sessionGeneration: "2"
        }))
        compare(state.sessionGeneration, "2")
        compare(state.sessionStarted, false)
        compare(state.activity, "starting-preview")
        verify(state.startOver())

        state.receiveLine(event("start-over-complete", {
            sessionGeneration: "3"
        }))
        compare(state.sessionGeneration, "3")
        compare(state.hasTrustedDevice, false)
        compare(state.sessionStarted, false)
    }

    function test_start_over_failure_restores_retryable_trusted_state() {
        establishLiveSession()
        verify(state.startOver())

        state.receiveLine(event("failure", {
            reason: "dependency-unavailable"
        }))

        compare(state.startOverPending, false)
        compare(state.hasTrustedDevice, true)
        compare(state.sessionStarted, false)
        compare(state.sessionState, "disconnected")
        compare(state.pairingStage, "failed")
        compare(state.statusTitle, "Start over failed")
    }

    function test_live_preference_failure_preserves_confirmed_values() {
        establishLiveSession()
        verify(state.setPreferences(
                   true, 150, "low", ["home", "recent-apps", "back"], false))
        compare(state.keepConnected, false)
        compare(state.previewScale, 100)
        compare(state.videoQuality, "high")
        compare(state.androidModeShortcuts, true)

        state.receiveLine(event("failure", {
            reason: "dependency-unavailable"
        }))

        compare(preferenceFailureSpy.count, 1)
        compare(state.keepConnected, false)
        compare(state.previewScale, 100)
        compare(state.videoQuality, "high")
        compare(state.androidModeShortcuts, true)
    }

    function test_preferences_without_restart_do_not_change_session_identity() {
        establishLiveSession()

        state.receiveLine(event("preferences-updated", {
            keepConnected: true,
            previewScale: 125,
            videoQuality: "medium",
            quickActions: ["home", "back", "recent-apps"],
            androidModeShortcuts: false,
            sessionRestarted: false,
            sessionGeneration: "1"
        }))

        compare(state.sessionGeneration, "1")
        compare(state.sessionStarted, true)
        compare(state.androidModeShortcuts, false)
    }

    function test_action_results_use_protocol_v11_wire_values_without_changing_session_facts() {
        establishLiveSession()

        state.receiveLine(event("action-result", {
            requestId: "request-1",
            outcome: "failed",
            notificationCode: "target-failed",
            sessionGeneration: "1"
        }))
        state.receiveLine(event("action-result", {
            requestId: "request-2",
            outcome: "completed",
            sessionGeneration: "1"
        }))
        state.receiveLine(event("action-result", {
            requestId: "request-3",
            outcome: "stale-session",
            sessionGeneration: "1"
        }))

        state.receiveLine(event("action-result", {
            requestId: "legacy-request",
            outcome: "action-failed",
            notificationCode: "target-failed",
            sessionGeneration: "1"
        }))
        compare(state.sessionGeneration, "1")
        compare(state.sessionStarted, true)
        compare(state.hasTrustedDevice, true)
        compare(phoneTargetCompletedSpy.count, 3)
        compare(phoneTargetCompletedSpy.signalArguments[0].length, 3)
        compare(phoneTargetCompletedSpy.signalArguments[0][0], "request-1")
        compare(phoneTargetCompletedSpy.signalArguments[0][1], "failed")
        compare(phoneTargetCompletedSpy.signalArguments[0][2], "target-failed")
        compare(phoneTargetCompletedSpy.signalArguments[1][0], "request-2")
        compare(phoneTargetCompletedSpy.signalArguments[1][1], "completed")
        compare(phoneTargetCompletedSpy.signalArguments[1][2], "")
        compare(phoneTargetCompletedSpy.signalArguments[2][0], "request-3")
        compare(phoneTargetCompletedSpy.signalArguments[2][1], "stale-session")
        compare(phoneTargetCompletedSpy.signalArguments[2][2], "")
    }

    function test_stale_and_missing_epoch_events_are_ignored_before_any_fact_change() {
        state.receiveLine(event("ready", { hasTrustedDevice: false }))
        commandSpy.clear()

        state.receiveLine(event("ready", {
            hasTrustedDevice: true,
            sessionGeneration: "0"
        }, "16"))
        state.receiveLine(JSON.stringify({
            version: 11,
            type: "paired",
            sessionGeneration: "1"
        }))

        compare(state.hasTrustedDevice, false)
        compare(state.sessionGeneration, "0")
        compare(state.activity, "")
        compare(commandSpy.count, 0)
    }

    function test_stale_missing_and_skipped_generation_events_are_ignored() {
        establishTrustedBaseline()

        state.receiveLine(event("session-started", { sessionGeneration: "0" }))
        state.receiveLine(event("connecting", {}))
        state.receiveLine(event("connecting", { sessionGeneration: "2" }))

        compare(state.sessionGeneration, "0")
        compare(state.sessionStarted, false)
        compare(state.activity, "")

        state.receiveLine(event("connecting", { sessionGeneration: "1" }))
        state.receiveLine(event("session-started", { sessionGeneration: "0" }))
        compare(state.sessionGeneration, "1")
        compare(state.sessionStarted, false)
        compare(state.activity, "connecting")
    }

    function test_helper_epoch_change_preserves_trusted_fact_until_ready_baseline() {
        establishLiveSession()
        state.reset()
        compare(state.hasTrustedDevice, true)

        state.helperEpoch = "18"

        compare(state.helperReady, false)
        compare(state.hasTrustedDevice, true)
        compare(state.sessionState, "disconnected")
        compare(state.sessionGeneration, "")
        compare(state.sessionStarted, false)
        state.receiveLine(event("ready", {
            hasTrustedDevice: false,
            sessionGeneration: "0"
        }, "18"))
        compare(state.helperReady, true)
        compare(state.hasTrustedDevice, false)
        compare(state.sessionGeneration, "0")
    }

    function test_start_over_clears_live_facts_and_rejects_session_reentry() {
        establishLiveSession()
        commandSpy.clear()

        verify(state.startOver())
        compare(state.hasTrustedDevice, false)
        compare(state.sessionStarted, false)
        compare(state.startOverPending, true)
        compare(state.pairingStage, "starting-over")
        compare(commandAt(0).type, "start-over")

        state.receiveLine(event("session-started", {
            sessionGeneration: "1"
        }))
        compare(state.sessionStarted, false)
        compare(state.pairingStage, "starting-over")

        state.receiveLine(event("session-ended", {
            sessionGeneration: "2"
        }))
        state.receiveLine(event("start-over-complete", {
            sessionGeneration: "2"
        }))
        compare(state.startOverPending, false)
        compare(state.hasTrustedDevice, false)
        compare(state.sessionGeneration, "2")
    }

    function test_epoch_only_failure_is_handled_during_setup_but_not_live() {
        establishTrustedBaseline()
        state.receiveLine(event("failure", {
            reason: "network-unavailable"
        }))
        compare(state.reason, "network-unavailable")
        compare(state.hasTrustedDevice, true)

        establishLiveSession()
        state.receiveLine(event("failure", {
            reason: "dependency-unavailable"
        }))
        compare(state.sessionStarted, true)
        compare(state.reason, "")
    }

    function test_local_integration_failure_fails_closed_until_helper_restart() {
        establishLiveSession()

        state.localIntegrationFailure()
        compare(state.helperReady, true)
        compare(state.hasTrustedDevice, true)
        compare(state.sessionStarted, false)
        compare(state.localIntegrationAvailable, false)
        compare(state.reason, "dependency-unavailable")
        compare(state.statusTitle, "Android keyboard shortcuts unavailable")
        compare(state.statusDescription,
                "Desktop phone shortcuts could not be activated. The phone connection may still be retained.")

        state.receiveLine(event("session-started", {
            sessionGeneration: "1"
        }))
        compare(state.sessionStarted, false)
        compare(state.localIntegrationAvailable, false)

        state.retryLocalIntegration()
        compare(state.localIntegrationAvailable, true)
        compare(state.helperReady, true)

        state.receiveLine(event("session-started", {
            sessionGeneration: "1"
        }))
        compare(state.sessionStarted, false)

        state.localIntegrationFailure()
        compare(state.localIntegrationAvailable, false)
        compare(state.helperReady, true)

        state.helperEpoch = "18"
        compare(state.localIntegrationAvailable, true)
        compare(state.hasTrustedDevice, true)
    }

    function test_session_bound_commands_carry_both_decimal_string_identities() {
        establishLiveSession()
        commandSpy.clear()
        var expiresAtUnixMs = Date.now() + 2000

        state.sendPointerTap(0.25, 0.75, 1080, 2400)
        state.sendPointerSwipe(0.1, 0.2, 0.8, 0.9, 1080, 2400, 320)
        state.sendKeyInput("back")
        state.sendTextInput("a")
        state.sendPhoneTarget("request-1", "android.navigate.home", expiresAtUnixMs)

        compare(commandSpy.count, 5)
        for (var index = 0; index < commandSpy.count; ++index) {
            compare(commandAt(index).version, 11)
            compare(commandAt(index).helperEpoch, "17")
            compare(commandAt(index).sessionGeneration, "1")
        }
        compare(commandAt(4), {
            version: 11,
            type: "phone-target",
            requestId: "request-1",
            target: "android.navigate.home",
            expiresAtUnixMs: expiresAtUnixMs,
            helperEpoch: "17",
            sessionGeneration: "1"
        })
    }

    function test_preferences_schema_v1_has_no_passthrough_and_defaults_android_mode_on() {
        verify(state.setPreferences(
                   true, 150, "low", ["home", "recent-apps", "back"], true))

        compare(state.androidModeShortcuts, true)
        compare(state.commandPassthrough, undefined)
        compare(commandSpy.count, 1)
        compare(commandAt(0), {
            version: 11,
            type: "set-preferences",
            keepConnected: true,
            previewScale: 150,
            videoQuality: "low",
            quickActions: ["home", "recent-apps", "back"],
            androidModeShortcuts: true,
            helperEpoch: "17"
        })
    }

    function test_schema_v1_rejects_unreleased_passthrough_field() {
        var oldPreferences = defaultPreferences()
        oldPreferences.commandPassthrough = false

        state.receiveLine(event("ready", {
            hasTrustedDevice: false,
            preferences: oldPreferences
        }))

        compare(state.helperReady, false)
        compare(state.sessionGeneration, "")
        compare(commandSpy.count, 0)
    }

    function test_old_semantic_command_api_is_completely_removed() {
        compare(state.sendSemanticAction, undefined)
        compare(state.semanticActionCompleted, undefined)
        compare(state.commandPassthrough, undefined)
    }
    function test_scrcpy_configuration_is_reconciled_and_restart_is_admitted() {
        verify(state.setScrcpyConfiguration(
                   "0123456789abcdef",
                   ["--keep-active", "--stay-awake"]))
        compare(commandSpy.count, 0)

        state.receiveLine(event("ready", {
            hasTrustedDevice: true,
            scrcpyRevision: "cbf29ce484222325",
            screenOffRequested: false
        }))
        compare(commandSpy.count, 2)
        compare(commandAt(0), {
            version: 11,
            type: "set-scrcpy-args",
            helperEpoch: "17",
            sessionGeneration: "0",
            arguments: ["--keep-active", "--stay-awake"],
            expectedRevision: "cbf29ce484222325",
            newRevision: "0123456789abcdef",
            screenOffEnabled: false
        })
        compare(commandAt(1).type, "reconnect-trusted-device")

        state.receiveLine(event("scrcpy-args-updated", {
            sessionGeneration: "0",
            revision: "0123456789abcdef",
            screenOffEnabled: false,
            sessionRestarted: false
        }))
        compare(state.appliedScrcpyRevision, "0123456789abcdef")
        compare(state.effectiveScreenOff, false)
        compare(state.sessionGeneration, "0")
        compare(state.sessionStarted, false)
    }

    function test_first_valid_frame_enables_screen_off_at_most_once_per_generation() {
        state.firstFrameTimeoutMs = 20
        verify(state.setScrcpyConfiguration(
                   "0123456789abcdef",
                   ["--turn-screen-off"]))
        state.receiveLine(event("ready", {
            hasTrustedDevice: true,
            scrcpyRevision: "0123456789abcdef",
            screenOffRequested: true
        }))
        state.receiveLine(event("connecting", { sessionGeneration: "1" }))
        state.receiveLine(event("connected", { sessionGeneration: "1" }))
        state.receiveLine(event("session-starting", { sessionGeneration: "1" }))
        state.receiveLine(event("session-started", {
            sessionGeneration: "1",
            screenOffEnabled: true
        }))
        commandSpy.clear()

        verify(state.acknowledgePreviewReady("17", "1"))
        compare(commandSpy.count, 1)
        compare(commandAt(0), {
            version: 11,
            type: "preview-ready",
            helperEpoch: "17",
            sessionGeneration: "1"
        })
        wait(50)
        compare(commandSpy.count, 1)
        compare(state.effectiveScreenOff, true)
        compare(state.sessionStarted, true)
        compare(commandAt(0).type, "preview-ready")
    }

    function test_missing_first_frame_stops_session_with_preview_failed() {
        state.firstFrameTimeoutMs = 20
        establishLiveSession()
        state.previewSurfaceMounted = true
        commandSpy.clear()

        tryCompare(commandSpy, "count", 1)
        compare(commandAt(0), {
            version: 11,
            type: "stop-session",
            helperEpoch: "17",
            sessionGeneration: "1"
        })
        compare(state.statusTitle, "Preview failed")
        compare(state.statusDescription,
                "The phone connected but the panel never received a picture.")
        compare(state.connectionPresentationActive, false)
        compare(state.sessionState, "disconnected")
        compare(state.sessionStarted, false)
        verify(state.statusTitle !== "Phone unavailable")
        verify(state.statusDescription.indexOf("trusted Wi-Fi") < 0)

        state.receiveLine(event("session-stopped", { sessionGeneration: "2" }))
        compare(state.sessionState, "disconnected")
        compare(state.statusTitle, "Preview failed")
        compare(state.statusDescription,
                "The phone connected but the panel never received a picture.")
        compare(state.connectionPresentationActive, false)
    }

    function test_retain_unmounted_first_frame_timeout_does_not_stop_session() {
        state.keepConnected = true
        state.firstFrameTimeoutMs = 20
        establishLiveSession()
        state.previewSurfaceMounted = true
        state.previewSurfaceMounted = false
        commandSpy.clear()

        wait(50)
        compare(commandSpy.count, 0)
        compare(state.sessionStarted, true)
        verify(state.statusTitle !== "Preview failed")
        compare(state.statusTitle, "Phone connected")
    }

    function test_remount_after_retain_restarts_first_frame_watch() {
        state.keepConnected = true
        state.firstFrameTimeoutMs = 20
        establishLiveSession()
        state.previewSurfaceMounted = true
        state.previewSurfaceMounted = false
        commandSpy.clear()

        wait(50)
        compare(commandSpy.count, 0)
        compare(state.sessionStarted, true)
        verify(state.statusTitle !== "Preview failed")

        state.previewSurfaceMounted = true
        tryCompare(commandSpy, "count", 1)
        compare(commandAt(0), {
            version: 11,
            type: "stop-session",
            helperEpoch: "17",
            sessionGeneration: "1"
        })
        compare(state.statusTitle, "Preview failed")
        compare(state.sessionStarted, false)
    }


    function test_stale_scrcpy_update_retries_current_desired_revision_once() {
        state.receiveLine(event("ready", {
            hasTrustedDevice: true,
            scrcpyRevision: "cbf29ce484222325",
            screenOffRequested: false
        }))
        commandSpy.clear()
        verify(state.setScrcpyConfiguration(
                   "0123456789abcdef",
                   ["--keep-active"]))
        compare(commandSpy.count, 1)

        state.receiveLine(event("scrcpy-args-stale", {
            sessionGeneration: "1",
            revision: "cbf29ce484222325"
        }))
        compare(state.sessionGeneration, "1")
        compare(commandSpy.count, 2)
        compare(commandAt(1), {
            version: 11,
            type: "set-scrcpy-args",
            helperEpoch: "17",
            sessionGeneration: "1",
            arguments: ["--keep-active"],
            expectedRevision: "cbf29ce484222325",
            newRevision: "0123456789abcdef",
            screenOffEnabled: false
        })

        state.receiveLine(event("scrcpy-args-stale", {
            sessionGeneration: "1",
            revision: "cbf29ce484222325"
        }))
        compare(commandSpy.count, 2)
    }
    function test_replayed_snapshot_can_enable_screen_off_without_raw_arguments() {
        state.receiveLine(event("ready", {
            hasTrustedDevice: true,
            scrcpyRevision: "0123456789abcdef",
            screenOffRequested: true
        }))
        state.receiveLine(event("connecting", { sessionGeneration: "1" }))
        state.receiveLine(event("connected", { sessionGeneration: "1" }))
        state.receiveLine(event("session-starting", { sessionGeneration: "1" }))
        state.receiveLine(event("session-started", {
            sessionGeneration: "1",
            screenOffEnabled: false
        }))
        commandSpy.clear()

        verify(state.requestScreenOffAfterPreview("17", "1"))
        compare(commandAt(0), {
            version: 11,
            type: "set-scrcpy-args",
            helperEpoch: "17",
            sessionGeneration: "1",
            expectedRevision: "0123456789abcdef",
            newRevision: "0123456789abcdef",
            screenOffEnabled: true
        })
    }
    function test_preview_ready_is_generation_bound_and_sent_once_per_generation() {
        establishLiveSession()
        commandSpy.clear()

        verify(!state.acknowledgePreviewReady("16", "1"))
        verify(!state.acknowledgePreviewReady("17", "0"))
        compare(commandSpy.count, 0)

        verify(state.acknowledgePreviewReady("17", "1"))
        verify(!state.acknowledgePreviewReady("17", "1"))
        compare(commandSpy.count, 1)
        compare(commandAt(0), {
            version: 11,
            type: "preview-ready",
            helperEpoch: "17",
            sessionGeneration: "1"
        })

        state.receiveLine(event("session-starting", {
            sessionGeneration: "2"
        }))
        state.receiveLine(event("session-started", {
            sessionGeneration: "2"
        }))
        commandSpy.clear()

        verify(state.acknowledgePreviewReady("17", "2"))
        verify(!state.acknowledgePreviewReady("17", "2"))
        compare(commandSpy.count, 1)
        compare(commandAt(0), {
            version: 11,
            type: "preview-ready",
            helperEpoch: "17",
            sessionGeneration: "2"
        })
    }

}
