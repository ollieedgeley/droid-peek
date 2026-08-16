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

    function init() {
        state.reset()
        commandSpy.clear()
        cancellationSpy.clear()
    }

    function event(type, properties) {
        var value = properties || {}
        value.version = 1
        value.type = type
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
        state.receiveLine(event("ready"))

        compare(state.helperReady, true)
        compare(commandSpy.count, 1)
        var command = JSON.parse(commandSpy.signalArguments[0][0])
        compare(command.version, 1)
        compare(command.type, "start-qr-pairing")
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
        compare(command.version, 1)
        compare(command.type, "submit-manual-code")
        compare(command.code, "482913")
        compare(state.statusDescription.indexOf("482913"), -1)
    }

    function test_successful_pairing_enters_ready_state() {
        state.receiveLine(event("paired"))
        compare(state.sessionState, "ready")
        compare(state.pairingStage, "paired")
    }

    function test_commands_are_versioned_line_payloads() {
        state.startQrPairing()
        state.useManualCode()
        state.cancelPairing()

        compare(commandSpy.count, 3)
        compare(JSON.parse(commandSpy.signalArguments[0][0]).type, "start-qr-pairing")
        compare(JSON.parse(commandSpy.signalArguments[1][0]).type, "use-manual-code")
        compare(JSON.parse(commandSpy.signalArguments[2][0]).type, "cancel-pairing")
        compare(JSON.parse(commandSpy.signalArguments[0][0]).version, 1)
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
}
