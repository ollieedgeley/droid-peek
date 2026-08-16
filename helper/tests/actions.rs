use std::collections::HashMap;

use omarchy_android_helper::actions::{
    ActionClassification, ActionResult, ActionScope, VerificationStatus, bundled_action_manifest,
};
use omarchy_android_helper::input::AndroidKey;

#[test]
fn bundled_manifest_classifies_every_baseline_action_with_an_explicit_result() {
    let manifest = bundled_action_manifest().expect("valid bundled action manifest");
    let actions: HashMap<_, _> = manifest
        .actions
        .iter()
        .map(|action| (action.id.as_str(), action))
        .collect();

    assert_eq!(actions.len(), 7);
    assert_eq!(
        actions["toggle-android-panel"].result,
        ActionResult::PanelToggle
    );
    assert_eq!(actions["toggle-android-panel"].scope, ActionScope::Global);
    assert_eq!(
        actions["android-back"].result,
        ActionResult::KeyInput {
            key: AndroidKey::Back
        }
    );
    assert_eq!(
        actions["android-home"].result,
        ActionResult::KeyInput {
            key: AndroidKey::Home
        }
    );
    assert_eq!(
        actions["android-recent-apps"].result,
        ActionResult::KeyInput {
            key: AndroidKey::AppSwitch
        }
    );
    assert_eq!(
        actions["pointer-control"].result,
        ActionResult::PointerInput
    );
    assert_eq!(actions["typed-input"].result, ActionResult::TextInput);
    for id in [
        "android-back",
        "android-home",
        "android-recent-apps",
        "pointer-control",
        "typed-input",
    ] {
        assert_eq!(
            actions[id].verification.status,
            VerificationStatus::DeviceVerified
        );
        assert_eq!(actions[id].verification.android_versions, [16]);
    }
    assert_eq!(
        actions["open-universal-search"].classification,
        ActionClassification::ExplicitNonEquivalent
    );
    assert!(matches!(
        actions["open-universal-search"].result,
        ActionResult::Unsupported { .. }
    ));
    assert!(manifest.actions.iter().all(|action| {
        action.scope == ActionScope::Global || action.scope == ActionScope::FocusedPhone
    }));
}
