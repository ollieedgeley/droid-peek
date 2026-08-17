//! Typed, fail-closed contracts for semantic actions and per-device overrides.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::{
    input::AndroidKey,
    process::{CancellationToken, CommandFailure, CommandRequest, CommandRunner},
};

pub const ACTION_SCHEMA_VERSION: u8 = 3;
const LEGACY_UNIVERSAL_SEARCH_ID: &str = "open-universal-search";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum SemanticAction {
    ToggleAndroidPanel,
    PointerControl,
    TypedInput,
    OmarchyCloseCurrentWindow,
    OmarchyBrowser,
    OmarchyMenu,
    AndroidBack,
    AndroidHome,
    AndroidRecentApps,
    AndroidLaunchApp,
}

impl SemanticAction {
    pub const ALL: [Self; 10] = [
        Self::ToggleAndroidPanel,
        Self::PointerControl,
        Self::TypedInput,
        Self::OmarchyCloseCurrentWindow,
        Self::OmarchyBrowser,
        Self::OmarchyMenu,
        Self::AndroidBack,
        Self::AndroidHome,
        Self::AndroidRecentApps,
        Self::AndroidLaunchApp,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ToggleAndroidPanel => "toggle-android-panel",
            Self::PointerControl => "pointer-control",
            Self::TypedInput => "typed-input",
            Self::OmarchyCloseCurrentWindow => "omarchy-close-current-window",
            Self::OmarchyBrowser => "omarchy-browser",
            Self::OmarchyMenu => "omarchy-menu",
            Self::AndroidBack => "android-back",
            Self::AndroidHome => "android-home",
            Self::AndroidRecentApps => "android-recent-apps",
            Self::AndroidLaunchApp => "android-launch-app",
        }
    }
}

#[must_use]
pub fn valid_android_package(package: &str) -> bool {
    package.len() <= 255
        && package.split('.').count() >= 2
        && package.split('.').all(|segment| {
            let mut characters = segment.chars();
            characters
                .next()
                .is_some_and(|first| first.is_ascii_alphabetic())
                && characters.all(|character| character.is_ascii_alphanumeric() || character == '_')
        })
}

pub struct AdbActionAdapter<'a> {
    runner: &'a mut dyn CommandRunner,
    cancellation: &'a CancellationToken,
}

impl<'a> AdbActionAdapter<'a> {
    pub fn new(runner: &'a mut dyn CommandRunner, cancellation: &'a CancellationToken) -> Self {
        Self {
            runner,
            cancellation,
        }
    }

    pub fn open_standard_browser(&mut self, target: &str) -> Result<bool, CommandFailure> {
        self.runner
            .run(
                CommandRequest::new(
                    "adb",
                    [
                        "-s",
                        target,
                        "shell",
                        "am",
                        "start",
                        "-W",
                        "-a",
                        "android.intent.action.VIEW",
                        "-d",
                        "https://example.com",
                    ]
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
                ),
                self.cancellation,
            )
            .map(|output| output.succeeded)
    }

    pub fn launch_package(&mut self, target: &str, package: &str) -> Result<bool, CommandFailure> {
        self.runner
            .run(
                CommandRequest::new(
                    "adb",
                    [
                        "-s",
                        target,
                        "shell",
                        "monkey",
                        "-p",
                        package,
                        "-c",
                        "android.intent.category.LAUNCHER",
                        "1",
                    ]
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
                ),
                self.cancellation,
            )
            .map(|output| output.succeeded)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VersionEnvelope {
    schema_version: u8,
}

#[derive(Debug, Eq, PartialEq)]
pub struct ActionManifest {
    schema_version: u8,
    actions: Vec<ActionDefinition>,
}

impl ActionManifest {
    #[must_use]
    pub const fn schema_version(&self) -> u8 {
        self.schema_version
    }

    #[must_use]
    pub fn actions(&self) -> &[ActionDefinition] {
        &self.actions
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct UncheckedActionManifest {
    schema_version: u8,
    actions: Vec<ActionDefinition>,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActionDefinition {
    pub id: String,
    pub label: String,
    pub classification: ActionClassification,
    pub scope: ActionScope,
    pub result: ActionResult,
    pub override_policy: ActionOverridePolicy,
    pub override_targets: Vec<ActionTargetDefinition>,
    pub verification: ActionVerification,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ActionClassification {
    DirectEquivalent,
    ClearlyLabelledAdaptation,
    AndroidNativeExtension,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ActionScope {
    Global,
    FocusedPhone,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ActionCapability {
    LauncherSearch,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum ActionResult {
    PanelToggle {},
    KeyInput { key: AndroidKey },
    PointerInput {},
    TextInput {},
    Capability { capability: ActionCapability },
    StandardBrowserIntent {},
    Unavailable { reason: String },
    PackageLaunch {},
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ActionOverridePolicy {
    NotAllowed,
    ValidatedManifestAction,
    ValidatedTextInputAdapter,
    ConfirmedCapability,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActionTargetDefinition {
    pub id: String,
    pub result: ActionResult,
    pub verification: ActionVerification,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActionVerification {
    pub status: VerificationStatus,
    pub android_versions: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum VerificationStatus {
    AutomatedContract,
    DeviceVerified,
    PendingHardware,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActionManifestError {
    InvalidJson,
    UnsupportedVersion,
    DuplicateId,
    LegacyActionId,
    InvalidDefinition,
    InvalidVerification,
}

pub fn parse_action_manifest(input: &str) -> Result<ActionManifest, ActionManifestError> {
    let version: VersionEnvelope =
        serde_json::from_str(input).map_err(|_| ActionManifestError::InvalidJson)?;
    if version.schema_version != ACTION_SCHEMA_VERSION {
        return Err(ActionManifestError::UnsupportedVersion);
    }

    let unchecked: UncheckedActionManifest =
        serde_json::from_str(input).map_err(|_| ActionManifestError::InvalidJson)?;
    let manifest = ActionManifest {
        schema_version: unchecked.schema_version,
        actions: unchecked.actions,
    };
    validate_manifest(&manifest)?;
    Ok(manifest)
}

pub fn bundled_action_manifest() -> Result<ActionManifest, ActionManifestError> {
    parse_action_manifest(include_str!("../../actions.json"))
}

fn validate_manifest(manifest: &ActionManifest) -> Result<(), ActionManifestError> {
    let mut action_ids = HashSet::with_capacity(manifest.actions.len());
    for action in &manifest.actions {
        if action.id.is_empty() || action.label.is_empty() {
            return Err(ActionManifestError::InvalidDefinition);
        }
        if action.id == LEGACY_UNIVERSAL_SEARCH_ID {
            return Err(ActionManifestError::LegacyActionId);
        }
        if !action_ids.insert(action.id.as_str()) {
            return Err(ActionManifestError::DuplicateId);
        }
        validate_verification(&action.verification)?;

        let unavailable = matches!(action.result, ActionResult::Unavailable { .. });
        if unavailable != (action.classification == ActionClassification::Unavailable) {
            return Err(ActionManifestError::InvalidDefinition);
        }
        if action.override_policy == ActionOverridePolicy::NotAllowed
            && !action.override_targets.is_empty()
        {
            return Err(ActionManifestError::InvalidDefinition);
        }

        let mut target_ids = HashSet::with_capacity(action.override_targets.len());
        for target in &action.override_targets {
            if target.id.is_empty() || !target_ids.insert(target.id.as_str()) {
                return Err(ActionManifestError::InvalidDefinition);
            }
            if target.verification.status != VerificationStatus::DeviceVerified
                || !override_target_is_compatible(action.override_policy, &target.result)
            {
                return Err(ActionManifestError::InvalidDefinition);
            }
            validate_verification(&target.verification)?;
        }
    }
    Ok(())
}

fn override_target_is_compatible(policy: ActionOverridePolicy, result: &ActionResult) -> bool {
    matches!(
        (policy, result),
        (
            ActionOverridePolicy::ValidatedManifestAction,
            ActionResult::KeyInput { .. }
        ) | (
            ActionOverridePolicy::ValidatedTextInputAdapter,
            ActionResult::TextInput {}
        ) | (
            ActionOverridePolicy::ConfirmedCapability,
            ActionResult::Capability { .. }
        )
    )
}

fn validate_verification(verification: &ActionVerification) -> Result<(), ActionManifestError> {
    let versions_are_valid = match verification.status {
        VerificationStatus::DeviceVerified => !verification.android_versions.is_empty(),
        VerificationStatus::AutomatedContract | VerificationStatus::PendingHardware => {
            verification.android_versions.is_empty()
        }
    };
    versions_are_valid
        .then_some(())
        .ok_or(ActionManifestError::InvalidVerification)
}

#[must_use]
pub fn resolve_action<'a>(
    manifest: &'a ActionManifest,
    action_id: &str,
) -> Option<&'a ActionResult> {
    manifest
        .actions
        .iter()
        .find(|action| action.id == action_id)
        .map(|action| &action.result)
}
