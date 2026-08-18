import QtQuick
import QtTest
import "../../qml/state"

TestCase {
    name: "PhoneTargetRouter"

    PhoneTargetRouter {
        id: router
        applicationState: "interactive"
        helperEpoch: "17"
        sessionGeneration: "3"
    }

    SignalSpy {
        id: targetSpy
        target: router
        signalName: "phoneTargetRequested"
    }
    SignalSpy {
        id: failureNotificationSpy
        target: router
        signalName: "phoneTargetFailureNotificationRequested"
    }


    function init() {
        router.applicationState = "interactive"
        router.helperEpoch = "17"
        router.sessionGeneration = "3"
        router.failureNotificationTimes = ({})
        targetSpy.clear()
        failureNotificationSpy.clear()
    }

    function envelope(requestId, target, deadline) {
        return {
            requestId: requestId,
            target: target,
            expiresAtUnixMs: deadline === undefined
                               ? Date.now() + 2000 : deadline
        }
    }

    function test_interactive_phone_target_is_admitted_with_current_identity() {
        var request = envelope("request-1", "android.browser.default")

        verify(router.acceptPhoneTarget(request))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0], {
            requestId: request.requestId,
            target: request.target,
            expiresAtUnixMs: request.expiresAtUnixMs,
            helperEpoch: "17",
            sessionGeneration: "3"
        })
    }

    function test_typed_package_target_is_preserved() {
        var request = envelope("request-package", {
            type: "android.app.launch",
            package: "com.example.notes"
        })

        verify(router.acceptPhoneTarget(request))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0].target, request.target)
    }

    function test_only_interactive_state_admits_phone_targets_data() {
        return [
            { tag: "closed", state: "closed" },
            { tag: "setup", state: "setup" },
            { tag: "recovering", state: "recovering" },
            { tag: "management", state: "management" }
        ]
    }

    function test_only_interactive_state_admits_phone_targets(data) {
        router.applicationState = data.state

        verify(!router.acceptPhoneTarget(
                   envelope("request-state", "android.navigate.home")))
        compare(targetSpy.count, 0)
    }

    function test_missing_session_identity_rejects_before_dispatch_data() {
        return [
            { tag: "missing epoch", propertyName: "helperEpoch", value: "" },
            { tag: "non-decimal epoch", propertyName: "helperEpoch", value: "epoch-17" },
            { tag: "missing generation", propertyName: "sessionGeneration", value: "" },
            { tag: "non-decimal generation", propertyName: "sessionGeneration", value: "3.0" }
        ]
    }

    function test_missing_session_identity_rejects_before_dispatch(data) {
        router[data.propertyName] = data.value

        verify(!router.acceptPhoneTarget(
                   envelope("request-identity", "android.navigate.home")))
        compare(targetSpy.count, 0)
    }

    function test_invalid_envelopes_are_rejected_data() {
        return [
            { tag: "missing request id", request: envelope("", "android.navigate.home") },
            { tag: "unsafe request id", request: envelope("../unsafe", "android.navigate.home") },
            { tag: "empty named target", request: envelope("request-empty", "") },
            { tag: "unsafe named target", request: envelope("request-unsafe-target", "android target") },
            { tag: "bad package", request: envelope("request-package", { type: "android.app.launch", package: "bad package" }) },
            { tag: "expired", request: envelope("request-expired", "android.navigate.home", Date.now() - 1) },
            { tag: "deadline too far", request: envelope("request-late", "android.navigate.home", Date.now() + 3000) },
            { tag: "fractional deadline", request: envelope("request-fraction", "android.navigate.home", Date.now() + 1000.5) }
        ]
    }

    function test_invalid_envelopes_are_rejected(data) {
        verify(!router.acceptPhoneTarget(data.request))
        compare(targetSpy.count, 0)
    }

    function test_unknown_safe_named_target_reaches_helper_validation() {
        var request = envelope("request-unknown", "android.unsupported")

        verify(router.acceptPhoneTarget(request))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0].target, "android.unsupported")
    }

    function test_failed_results_map_to_redacted_notifications_data() {
        return [
            {
                tag: "invalid target",
                code: "invalid-target",
                message: "Android shortcut is not supported."
            },
            {
                tag: "target failed",
                code: "target-failed",
                message: "Android shortcut failed."
            },
            {
                tag: "target timed out",
                code: "target-timed-out",
                message: "Android shortcut timed out."
            },
            {
                tag: "invalid deadline",
                code: "invalid-deadline",
                message: "Android shortcut expired."
            }
        ]
    }

    function test_failed_results_map_to_redacted_notifications(data) {
        verify(router.consumePhoneTargetResult("failed", data.code))

        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0][0], data.message)
        compare(failureNotificationSpy.signalArguments[0][1],
                "omarchy-android-phone-target-" + data.code)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("android.") < 0)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("omarchy-shell") < 0)
    }

    function test_identical_failure_burst_is_coalesced() {
        verify(router.consumePhoneTargetResult("failed", "target-failed"))
        verify(router.consumePhoneTargetResult("failed", "target-failed"))

        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0][1],
                "omarchy-android-phone-target-target-failed")
    }

    function test_distinct_failures_are_not_coalesced() {
        verify(router.consumePhoneTargetResult("failed", "target-failed"))
        verify(router.consumePhoneTargetResult("failed", "invalid-target"))

        compare(failureNotificationSpy.count, 2)
    }

    function test_nonfailed_and_unknown_results_do_not_notify_data() {
        return [
            { tag: "completed", outcome: "completed", code: "" },
            { tag: "stale", outcome: "stale-session", code: "" },
            { tag: "unknown failure", outcome: "failed", code: "other" }
        ]
    }

    function test_nonfailed_and_unknown_results_do_not_notify(data) {
        verify(!router.consumePhoneTargetResult(data.outcome, data.code))
        compare(failureNotificationSpy.count, 0)
    }

    function test_supported_named_targets_are_exact_data() {
        return [
            { tag: "browser", target: "android.browser.default" },
            { tag: "home", target: "android.navigate.home" },
            { tag: "back", target: "android.navigate.back" },
            { tag: "recent apps", target: "android.recent-apps" }
        ]
    }

    function test_supported_named_targets_are_exact(data) {
        verify(router.acceptPhoneTarget(envelope("request-target", data.target)))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0].target, data.target)
    }

    function test_old_semantic_and_passthrough_routing_surface_is_removed() {
        compare(router.commandPassthrough, undefined)
        compare(router.routes, undefined)
        compare(router.customBindings, undefined)
        compare(router.semanticIntegrationEnabled, undefined)
        compare(router.sessionReady, undefined)
        compare(router.settingsOpen, undefined)
        compare(router.phoneFocused, undefined)
        compare(router.shortcutInhibitionRequested, undefined)
        compare(router.semanticActionRequested, undefined)
        compare(router.trigger, undefined)
    }
}
