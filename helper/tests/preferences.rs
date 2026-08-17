use std::{fs, os::unix::fs::PermissionsExt};

use omarchy_android_helper::preferences::{
    FileRenderPreferenceStore, PreviewSize, QuickAction, RenderPreferences, VideoQuality,
};
use tempfile::tempdir;

#[test]
fn defaults_are_medium_size_high_quality_and_native_actions() {
    assert_eq!(
        RenderPreferences::default(),
        RenderPreferences {
            preview_size: PreviewSize::Medium,
            video_quality: VideoQuality::High,
            quick_actions: [
                QuickAction::Back,
                QuickAction::Home,
                QuickAction::RecentApps
            ],
        }
    );
}

#[test]
fn preferences_round_trip_in_private_versioned_state() {
    let directory = tempdir().expect("temporary state directory");
    let store = FileRenderPreferenceStore::new(directory.path().join("omarchy-android"));
    let preferences = RenderPreferences {
        preview_size: PreviewSize::Large,
        video_quality: VideoQuality::Low,
        quick_actions: [
            QuickAction::Home,
            QuickAction::RecentApps,
            QuickAction::Back,
        ],
    };

    store.save(&preferences).expect("save preferences");

    assert_eq!(store.load().expect("load preferences"), preferences);
    let contents = fs::read_to_string(store.path()).expect("read preferences state");
    assert_eq!(
        contents,
        "{\"version\":1,\"previewSize\":\"large\",\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n"
    );
    assert_eq!(
        fs::metadata(store.path())
            .expect("preference file metadata")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
}

#[test]
fn malformed_preferences_are_removed_and_reset_to_defaults() {
    let directory = tempdir().expect("temporary state directory");
    let store = FileRenderPreferenceStore::new(directory.path().join("omarchy-android"));
    fs::create_dir_all(store.directory()).expect("create state directory");
    fs::write(
        store.path(),
        b"{\"version\":1,\"previewSize\":\"huge\",\"videoQuality\":\"high\",\"quickActions\":[]}\n",
    )
    .expect("write malformed preferences");

    assert_eq!(
        store.load().expect("load preferences"),
        RenderPreferences::default()
    );
    assert!(!store.path().exists());
}
