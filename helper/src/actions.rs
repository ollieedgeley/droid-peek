//! Typed contract for the bundled semantic action manifest.

use std::collections::HashSet;

use serde::Deserialize;

use crate::input::AndroidKey;

pub const ACTION_MANIFEST_VERSION: u8 = 1;

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActionManifest {
    pub schema_version: u8,
    pub actions: Vec<ActionDefinition>,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ActionDefinition {
    pub id: String,
    pub label: String,
    pub classification: ActionClassification,
    pub scope: ActionScope,
    pub result: ActionResult,
    pub verification: ActionVerification,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ActionClassification {
    DirectEquivalent,
    ClosestAdaptation,
    AndroidNativeExtension,
    ExplicitNonEquivalent,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ActionScope {
    Global,
    FocusedPhone,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum ActionResult {
    PanelToggle,
    KeyInput { key: AndroidKey },
    PointerInput,
    TextInput,
    Unsupported { reason: String },
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
    NotApplicable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActionManifestError {
    InvalidJson,
    UnsupportedVersion,
    InvalidDefinition,
}

pub fn bundled_action_manifest() -> Result<ActionManifest, ActionManifestError> {
    let manifest: ActionManifest = serde_json::from_str(include_str!("../../actions.json"))
        .map_err(|_| ActionManifestError::InvalidJson)?;
    if manifest.schema_version != ACTION_MANIFEST_VERSION {
        return Err(ActionManifestError::UnsupportedVersion);
    }
    let mut ids = HashSet::with_capacity(manifest.actions.len());
    if manifest.actions.is_empty()
        || manifest.actions.iter().any(|action| {
            action.id.is_empty()
                || action.label.is_empty()
                || !ids.insert(action.id.as_str())
                || matches!(
                    &action.result,
                    ActionResult::Unsupported { reason } if reason.is_empty()
                )
                || (action.verification.status == VerificationStatus::DeviceVerified
                    && action.verification.android_versions.is_empty())
                || (action.verification.status != VerificationStatus::DeviceVerified
                    && !action.verification.android_versions.is_empty())
        })
    {
        return Err(ActionManifestError::InvalidDefinition);
    }
    Ok(manifest)
}
