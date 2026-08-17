use std::collections::{HashMap, VecDeque};

use omarchy_android_helper::{
    actions::{
        ActionCapability, ActionClassification, ActionManifestError, ActionOverridePolicy,
        ActionResult, ActionScope, AdbActionAdapter, SemanticAction, VerificationStatus,
        bundled_action_manifest, parse_action_manifest, resolve_action,
    },
    input::AndroidKey,
    process::{CancellationToken, CommandFailure, CommandOutput, CommandRequest, CommandRunner},
};

#[test]
fn bundled_manifest_is_the_settled_android_16_default_profile() {
    let manifest = bundled_action_manifest().expect("valid bundled action manifest");
    assert_eq!(manifest.schema_version(), 3);

    let actions: HashMap<_, _> = manifest
        .actions()
        .iter()
        .map(|action| (action.id.as_str(), action))
        .collect();
    assert_eq!(actions.len(), 10);

    assert_eq!(
        actions["toggle-android-panel"].classification,
        ActionClassification::DirectEquivalent
    );
    assert_eq!(actions["toggle-android-panel"].scope, ActionScope::Global);
    assert_eq!(
        actions["toggle-android-panel"].result,
        ActionResult::PanelToggle {}
    );

    assert_eq!(
        actions["pointer-control"].result,
        ActionResult::PointerInput {}
    );
    assert_eq!(actions["typed-input"].result, ActionResult::TextInput {});
    assert_eq!(
        actions["typed-input"].override_policy,
        ActionOverridePolicy::ValidatedTextInputAdapter
    );

    assert_eq!(
        actions["omarchy-menu"].classification,
        ActionClassification::ClearlyLabelledAdaptation
    );
    assert_eq!(
        actions["omarchy-menu"].result,
        ActionResult::Capability {
            capability: ActionCapability::LauncherSearch,
        }
    );
    assert_eq!(
        actions["omarchy-menu"].override_policy,
        ActionOverridePolicy::ConfirmedCapability
    );

    assert_eq!(
        actions["omarchy-close-current-window"].classification,
        ActionClassification::ClearlyLabelledAdaptation
    );
    assert_eq!(
        actions["omarchy-close-current-window"].result,
        ActionResult::KeyInput {
            key: AndroidKey::Home,
        }
    );
    assert_eq!(
        actions["omarchy-close-current-window"].override_policy,
        ActionOverridePolicy::NotAllowed
    );

    assert_eq!(
        actions["omarchy-browser"].result,
        ActionResult::StandardBrowserIntent {}
    );

    assert_eq!(
        actions["omarchy-browser"].verification.status,
        VerificationStatus::DeviceVerified
    );
    assert_eq!(
        actions["omarchy-browser"].verification.android_versions,
        [16]
    );

    assert_eq!(
        actions["android-launch-app"].result,
        ActionResult::PackageLaunch {}
    );
    assert_eq!(
        actions["android-launch-app"].verification.status,
        VerificationStatus::AutomatedContract
    );

    for id in ["android-back", "android-home", "android-recent-apps"] {
        assert_eq!(
            actions[id].classification,
            ActionClassification::AndroidNativeExtension
        );
        assert_eq!(
            actions[id].override_policy,
            ActionOverridePolicy::ValidatedManifestAction
        );
        assert_eq!(
            actions[id].verification.status,
            VerificationStatus::DeviceVerified
        );
        assert_eq!(actions[id].verification.android_versions, [16]);
    }

    assert!(!actions.contains_key("open-universal-search"));
    assert!(manifest.actions().iter().all(|action| {
        action.scope == ActionScope::Global || action.scope == ActionScope::FocusedPhone
    }));
}

#[test]
fn version_one_manifest_is_rejected_instead_of_reinterpreting_legacy_search() {
    let legacy = r#"{
        "schemaVersion": 1,
        "actions": [{
            "id": "open-universal-search",
            "label": "Open universal search",
            "classification": "explicit-non-equivalent",
            "scope": "focused-phone",
            "result": {"kind": "unsupported", "reason": "legacy"},
            "verification": {"status": "pending-hardware", "androidVersions": []}
        }]
    }"#;

    assert_eq!(
        parse_action_manifest(legacy),
        Err(ActionManifestError::UnsupportedVersion)
    );
}

#[test]
fn manifest_rejects_duplicate_ids_and_unverified_device_claims() {
    let duplicate_ids = r#"{
        "schemaVersion": 3,
        "actions": [
            {
                "id": "android-back",
                "label": "Back",
                "classification": "android-native-extension",
                "scope": "focused-phone",
                "result": {"kind": "key-input", "key": "back"},
                "overridePolicy": "validated-manifest-action",
                "overrideTargets": [],
                "verification": {"status": "device-verified", "androidVersions": [16]}
            },
            {
                "id": "android-back",
                "label": "Back again",
                "classification": "android-native-extension",
                "scope": "focused-phone",
                "result": {"kind": "key-input", "key": "back"},
                "overridePolicy": "validated-manifest-action",
                "overrideTargets": [],
                "verification": {"status": "device-verified", "androidVersions": [16]}
            }
        ]
    }"#;
    assert_eq!(
        parse_action_manifest(duplicate_ids),
        Err(ActionManifestError::DuplicateId)
    );

    let false_device_claim = duplicate_ids.replace(
        "\"status\": \"device-verified\", \"androidVersions\": [16]",
        "\"status\": \"pending-hardware\", \"androidVersions\": [16]",
    );
    assert_eq!(
        parse_action_manifest(&false_device_claim),
        Err(ActionManifestError::InvalidVerification)
    );
}

#[test]
fn bundled_actions_resolve_directly_and_unknown_actions_do_not() {
    let manifest = bundled_action_manifest().expect("valid bundled action manifest");

    assert_eq!(
        resolve_action(&manifest, "android-back"),
        Some(&ActionResult::KeyInput {
            key: AndroidKey::Back,
        })
    );
    assert!(resolve_action(&manifest, "unknown-action").is_none());
}

#[test]
fn package_hard_codes_and_unverified_override_targets_are_rejected() {
    let package_target = r#"{
        "schemaVersion": 3,
        "actions": [{
            "id": "omarchy-browser",
            "label": "Open phone browser",
            "classification": "direct-equivalent",
            "scope": "focused-phone",
            "result": {
                "kind": "standard-browser-intent",
                "package": "com.example.browser"
            },
            "overridePolicy": "not-allowed",
            "overrideTargets": [],
            "verification": {"status": "pending-hardware", "androidVersions": []}
        }]
    }"#;
    assert_eq!(
        parse_action_manifest(package_target),
        Err(ActionManifestError::InvalidJson)
    );

    let unverified_target = r#"{
        "schemaVersion": 3,
        "actions": [{
            "id": "android-back",
            "label": "Back",
            "classification": "android-native-extension",
            "scope": "focused-phone",
            "result": {"kind": "key-input", "key": "back"},
            "overridePolicy": "validated-manifest-action",
            "overrideTargets": [{
                "id": "home-instead",
                "result": {"kind": "key-input", "key": "home"},
                "verification": {"status": "pending-hardware", "androidVersions": []}
            }],
            "verification": {"status": "device-verified", "androidVersions": [16]}
        }]
    }"#;
    assert_eq!(
        parse_action_manifest(unverified_target),
        Err(ActionManifestError::InvalidDefinition)
    );

    let incompatible_target = unverified_target.replace(
        r#""result": {"kind": "key-input", "key": "home"},
                "verification": {"status": "pending-hardware", "androidVersions": []}"#,
        r#""result": {"kind": "text-input"},
                "verification": {"status": "device-verified", "androidVersions": [16]}"#,
    );
    assert_eq!(
        parse_action_manifest(&incompatible_target),
        Err(ActionManifestError::InvalidDefinition)
    );
}

#[derive(Default)]
struct FakeActionRunner {
    requests: Vec<CommandRequest>,
    outputs: VecDeque<Result<CommandOutput, CommandFailure>>,
}

impl CommandRunner for FakeActionRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        _cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        self.requests.push(request);
        self.outputs
            .pop_front()
            .unwrap_or(Ok(CommandOutput { succeeded: true }))
    }
}

#[test]
fn browser_adapter_uses_only_a_package_free_standard_intent() {
    let mut runner = FakeActionRunner::default();
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    adapter
        .open_standard_browser("device.local:38100")
        .expect("browser intent succeeds");

    assert_eq!(runner.requests.len(), 1);
    assert_eq!(runner.requests[0].program(), "adb");
    assert_eq!(
        runner.requests[0].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "am",
            "start",
            "-W",
            "-a",
            "android.intent.action.VIEW",
            "-d",
            "https://example.com"
        ]
    );
    assert!(
        runner.requests[0]
            .arguments()
            .iter()
            .all(|argument| argument != "--package" && argument != "-n")
    );
}

#[test]
fn package_launch_adapter_targets_one_launcher_activity_with_monkey() {
    let mut runner = FakeActionRunner::default();
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    adapter
        .launch_package("device.local:38100", "com.example.notes")
        .expect("package launch succeeds");

    assert_eq!(runner.requests.len(), 1);
    assert_eq!(runner.requests[0].program(), "adb");
    assert_eq!(
        runner.requests[0].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "monkey",
            "-p",
            "com.example.notes",
            "-c",
            "android.intent.category.LAUNCHER",
            "1"
        ]
    );
}

#[test]
fn browser_adapter_reports_unhandled_process_outcomes() {
    let mut runner = FakeActionRunner {
        requests: Vec::new(),
        outputs: VecDeque::from([
            Ok(CommandOutput { succeeded: false }),
            Err(CommandFailure::Cancelled),
        ]),
    };
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    assert_eq!(
        adapter.open_standard_browser("device.local:38100"),
        Ok(false)
    );
    assert!(adapter.open_standard_browser("device.local:38100").is_err());
}

#[test]
fn semantic_action_ids_match_the_bundled_matrix_exactly() {
    let manifest = bundled_action_manifest().expect("valid bundled action manifest");
    let manifest_ids: HashMap<_, _> = manifest
        .actions()
        .iter()
        .map(|action| (action.id.as_str(), ()))
        .collect();

    assert_eq!(manifest_ids.len(), SemanticAction::ALL.len());
    assert!(
        SemanticAction::ALL
            .iter()
            .all(|action| manifest_ids.contains_key(action.as_str()))
    );
}
