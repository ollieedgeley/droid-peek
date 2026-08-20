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
        router.pendingLabels = ({})
        targetSpy.clear()
        failureNotificationSpy.clear()
    }

    function envelope(requestId, target, deadline, description) {
        var request = {
            requestId: requestId,
            target: target,
            expiresAtUnixMs: deadline === undefined
                               ? Date.now() + 2000 : deadline
        }
        if (description !== undefined)
            request.description = description
        return request
    }

    function test_interactive_phone_target_is_admitted_with_current_identity() {
        var request = envelope("request-1", "android.navigate.home")

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

    function test_typed_component_target_is_preserved_data() {
        return [
            {
                tag: "full activity",
                target: {
                    type: "android.component.launch",
                    package: "com.oppo.quicksearchbox",
                    activity: "com.oplus.globalsearch.ui.SearchActivity"
                }
            },
            {
                tag: "shorthand activity",
                target: {
                    type: "android.component.launch",
                    package: "com.samsung.android.app.galaxyfinder",
                    activity: ".GalaxyFinderActivity"
                }
            },
            {
                tag: "non package shape",
                target: {
                    type: "android.component.launch",
                    package: "bad package",
                    activity: "Search Activity"
                }
            }
        ]
    }

    function test_typed_component_target_is_preserved(data) {
        var request = envelope("request-component", data.target)

        verify(router.acceptPhoneTarget(request))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0].target, request.target)
    }

    function test_key_event_targets_are_admitted_lexically_data() {
        return [
            {
                tag: "supported key",
                target: {
                    type: "android.keyevent",
                    key: "volume-up"
                }
            },
            {
                tag: "unsupported but lexically valid key",
                target: {
                    type: "android.keyevent",
                    key: "future-key"
                }
            }
        ]
    }

    function test_key_event_targets_are_admitted_lexically(data) {
        var request = envelope("request-key-event", data.target)

        verify(router.acceptPhoneTarget(request))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0], {
            requestId: request.requestId,
            target: data.target,
            expiresAtUnixMs: request.expiresAtUnixMs,
            helperEpoch: "17",
            sessionGeneration: "3"
        })
    }

    function test_malformed_key_event_targets_are_rejected_data() {
        return [
            { tag: "target array", target: ["android.keyevent", "volume-up"] },
            { tag: "missing type", target: { key: "volume-up" } },
            { tag: "missing key", target: { type: "android.keyevent" } },
            { tag: "extra field", target: { type: "android.keyevent", key: "volume-up", repeat: 2 } },
            { tag: "key array", target: { type: "android.keyevent", key: ["volume-up"] } },
            { tag: "empty key", target: { type: "android.keyevent", key: "" } },
            { tag: "uppercase key", target: { type: "android.keyevent", key: "Volume-Up" } },
            { tag: "underscore", target: { type: "android.keyevent", key: "volume_up" } },
            { tag: "leading hyphen", target: { type: "android.keyevent", key: "-volume-up" } },
            { tag: "trailing hyphen", target: { type: "android.keyevent", key: "volume-up-" } },
            { tag: "empty segment", target: { type: "android.keyevent", key: "volume--up" } },
            { tag: "whitespace", target: { type: "android.keyevent", key: "volume up" } },
            { tag: "numeric segment", target: { type: "android.keyevent", key: "volume-2" } },
            { tag: "trailing newline", target: { type: "android.keyevent", key: "volume-up\n" } },
            { tag: "trailing carriage return", target: { type: "android.keyevent", key: "volume-up\r" } },
            { tag: "trailing line separator", target: { type: "android.keyevent", key: "volume-up\u2028" } },
            { tag: "trailing paragraph separator", target: { type: "android.keyevent", key: "volume-up\u2029" } }
        ]
    }

    function test_malformed_key_event_targets_are_rejected(data) {
        verify(!router.acceptPhoneTarget(
                   envelope("request-invalid-key-event", data.target)))
        compare(targetSpy.count, 0)
    }

    function test_malformed_component_targets_notify_locally_data() {
        return [
            {
                tag: "missing activity",
                target: {
                    type: "android.component.launch",
                    package: "com.example.app"
                }
            },
            {
                tag: "missing package",
                target: {
                    type: "android.component.launch",
                    activity: ".SearchActivity"
                }
            },
            {
                tag: "empty package",
                target: {
                    type: "android.component.launch",
                    package: "",
                    activity: ".SearchActivity"
                }
            },
            {
                tag: "empty activity",
                target: {
                    type: "android.component.launch",
                    package: "com.example.app",
                    activity: ""
                }
            },
            {
                tag: "nonstring package",
                target: {
                    type: "android.component.launch",
                    package: 1,
                    activity: ".SearchActivity"
                }
            },
            {
                tag: "nonstring activity",
                target: {
                    type: "android.component.launch",
                    package: "com.example.app",
                    activity: ["SearchActivity"]
                }
            },
            {
                tag: "extra field",
                target: {
                    type: "android.component.launch",
                    package: "com.example.app",
                    activity: ".SearchActivity",
                    extra: true
                }
            }
        ]
    }

    function test_malformed_component_targets_notify_locally(data) {
        var request = envelope("request-malformed-component", data.target,
                               undefined, "Samsung Finder")

        verify(!router.acceptPhoneTarget(request))
        compare(targetSpy.count, 0)
        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0][0],
                "Android shortcut is not supported.")
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("Couldn't open") < 0)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("Samsung Finder") < 0)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("com.example") < 0)
    }

    function test_malformed_component_invalid_target_is_coalesced() {
        var target = {
            type: "android.component.launch",
            package: "com.example.app"
        }

        verify(!router.acceptPhoneTarget(envelope("request-a", target)))
        verify(!router.acceptPhoneTarget(envelope("request-b", target)))

        compare(targetSpy.count, 0)
        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0][0],
                "Android shortcut is not supported.")
    }

    function test_malformed_component_inadmissible_request_is_silent_data() {
        return [
            { tag: "missing epoch", propertyName: "helperEpoch", value: "" },
            {
                tag: "missing generation",
                propertyName: "sessionGeneration",
                value: ""
            },
            { tag: "expired deadline", expired: true },
            {
                tag: "extra envelope key",
                extraKey: "helperEpoch",
                extraValue: "16"
            }
        ]
    }

    function test_malformed_component_inadmissible_request_is_silent(data) {
        if (data.propertyName)
            router[data.propertyName] = data.value
        var request = envelope("request-malformed-component", {
            type: "android.component.launch",
            package: "com.example.app"
        }, data.expired ? Date.now() - 1 : undefined)
        if (data.extraKey)
            request[data.extraKey] = data.extraValue

        verify(!router.acceptPhoneTarget(request))
        compare(targetSpy.count, 0)
        compare(failureNotificationSpy.count, 0)
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

    function test_stale_request_identity_is_rejected_data() {
        return [
            {
                tag: "stale helper epoch",
                propertyName: "helperEpoch",
                value: "16"
            },
            {
                tag: "stale session generation",
                propertyName: "sessionGeneration",
                value: "2"
            }
        ]
    }

    function test_stale_request_identity_is_rejected(data) {
        var request = envelope("request-stale-identity", {
            type: "android.keyevent",
            key: "volume-up"
        })
        request[data.propertyName] = data.value

        verify(!router.acceptPhoneTarget(request))
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
            { tag: "fractional deadline", request: envelope("request-fraction", "android.navigate.home", Date.now() + 1000.5) },
            { tag: "request array", request: ["request-array"] },
            { tag: "missing target", request: { requestId: "request-missing-target", expiresAtUnixMs: Date.now() + 1000 } },
            { tag: "empty description", request: envelope("request-empty-desc", "android.navigate.home", undefined, "") },
            { tag: "nonstring description", request: envelope("request-num-desc", "android.navigate.home", undefined, 1) }
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
        verify(router.consumePhoneTargetResult("request-unlabeled",
                                               "failed", data.code))

        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0][0], data.message)
        compare(failureNotificationSpy.signalArguments[0].length, 1)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("android.") < 0)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("omarchy-shell") < 0)
    }

    function test_identical_failure_burst_is_coalesced() {
        verify(router.consumePhoneTargetResult("request-a", "failed",
                                               "target-failed"))
        verify(router.consumePhoneTargetResult("request-b", "failed",
                                               "target-failed"))

        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0].length, 1)
        compare(failureNotificationSpy.signalArguments[0][0],
                "Android shortcut failed.")
    }

    function test_distinct_failures_are_not_coalesced() {
        verify(router.consumePhoneTargetResult("request-a", "failed",
                                               "target-failed"))
        verify(router.consumePhoneTargetResult("request-b", "failed",
                                               "invalid-target"))

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
        verify(!router.consumePhoneTargetResult("request-other", data.outcome,
                                                data.code))
        compare(failureNotificationSpy.count, 0)
    }

    function test_supported_named_targets_are_exact_data() {
        return [
            { tag: "home", target: "android.navigate.home" },
            { tag: "back", target: "android.navigate.back" },
            { tag: "recent apps", target: "android.recent-apps" }
        ]
    }

    function test_supported_named_targets_are_exact(data) {
        verify(router.acceptPhoneTarget(envelope("request-target", data.target)))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0].target, data.target)
        compare(targetSpy.signalArguments[0][0].description, undefined)
    }

    function test_labeled_termux_failure_uses_binding_description() {
        var request = envelope("request-termux", {
            type: "android.app.launch",
            package: "com.termux"
        }, undefined, "Termux")

        verify(router.acceptPhoneTarget(request))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0], {
            requestId: request.requestId,
            target: request.target,
            expiresAtUnixMs: request.expiresAtUnixMs,
            helperEpoch: "17",
            sessionGeneration: "3"
        })
        compare(targetSpy.signalArguments[0][0].description, undefined)

        verify(router.consumePhoneTargetResult(request.requestId, "failed",
                                               "target-failed"))
        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0][0],
                "Couldn't open Termux.")
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("com.termux") < 0)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("android.") < 0)
    }

    function test_labeled_component_failure_uses_binding_description() {
        var request = envelope("request-component", {
            type: "android.component.launch",
            package: "com.samsung.android.app.galaxyfinder",
            activity: ".GalaxyFinderActivity"
        }, undefined, "Samsung Finder")

        verify(router.acceptPhoneTarget(request))
        compare(targetSpy.count, 1)
        compare(targetSpy.signalArguments[0][0], {
            requestId: request.requestId,
            target: request.target,
            expiresAtUnixMs: request.expiresAtUnixMs,
            helperEpoch: "17",
            sessionGeneration: "3"
        })
        compare(targetSpy.signalArguments[0][0].description, undefined)

        verify(router.consumePhoneTargetResult(request.requestId, "failed",
                                               "target-failed"))
        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0][0],
                "Couldn't open Samsung Finder.")
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("com.samsung") < 0)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("GalaxyFinder") < 0)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("android.") < 0)
    }

    function test_labeled_non_app_failures_keep_typed_sentence_data() {
        return [
            {
                tag: "home timed out",
                requestId: "request-home",
                target: "android.navigate.home",
                description: "Home",
                code: "target-timed-out",
                message: "Android shortcut timed out."
            },
            {
                tag: "copy failed",
                requestId: "request-copy",
                target: {
                    type: "android.keyevent",
                    key: "copy"
                },
                description: "Copy",
                code: "target-failed",
                message: "Android shortcut failed."
            }
        ]
    }

    function test_labeled_non_app_failures_keep_typed_sentence(data) {
        var request = envelope(data.requestId, data.target, undefined,
                               data.description)

        verify(router.acceptPhoneTarget(request))
        verify(router.consumePhoneTargetResult(request.requestId, "failed",
                                               data.code))

        compare(failureNotificationSpy.count, 1)
        compare(failureNotificationSpy.signalArguments[0][0], data.message)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf("Couldn't open") < 0)
        verify(failureNotificationSpy.signalArguments[0][0]
               .indexOf(data.description) < 0)
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
