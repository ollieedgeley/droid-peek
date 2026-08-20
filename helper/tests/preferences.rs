use std::{fs, os::unix::fs::PermissionsExt};

use droid_peek_helper::preferences::{
    FilePreferenceStore, Preferences, PreviewScale, QuickAction, VideoQuality,
};
use tempfile::tempdir;

#[test]
fn schema_one_defaults_enable_android_mode_shortcuts() {
    assert_eq!(
        Preferences::default(),
        Preferences {
            keep_connected: false,
            android_mode_shortcuts: true,
            preview_scale: PreviewScale::default(),
            video_quality: VideoQuality::High,
            quick_actions: [
                QuickAction::Back,
                QuickAction::Home,
                QuickAction::RecentApps
            ],
        }
    );
    assert_eq!(PreviewScale::default().percent(), 100);
}

#[test]
fn preferences_round_trip_in_private_schema_one_state_without_passthrough() {
    let directory = tempdir().expect("temporary state directory");
    let store = FilePreferenceStore::new(directory.path().join("droid-peek"));
    let preferences = Preferences {
        keep_connected: true,
        android_mode_shortcuts: false,
        preview_scale: PreviewScale::new(150).expect("valid preview scale"),
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
        "{\"version\":1,\"keepConnected\":true,\"androidModeShortcuts\":false,\"previewScale\":150,\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n"
    );
    assert!(!contents.contains("commandPassthrough"));
    assert_eq!(
        fs::metadata(store.path())
            .expect("preference file metadata")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(directory.path().join("droid-peek"))
            .expect("preference directory metadata")
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
}

#[test]
fn non_schema_one_or_noncanonical_preferences_are_removed_without_migration() {
    let directory = tempdir().expect("temporary state directory");
    let store = FilePreferenceStore::new(directory.path().join("droid-peek"));
    fs::create_dir_all(directory.path().join("droid-peek")).expect("create state directory");

    for contents in [
        r#"{"version":1,"keepConnected":false,"androidModeShortcuts":true,"previewScale":151,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":1,"keepConnected":false,"androidModeShortcuts":"yes","previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":1,"keepConnected":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":1,"keepConnected":false,"androidModeShortcuts":true,"commandPassthrough":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":5,"keepConnected":false,"androidModeShortcuts":true,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":4,"keepConnected":false,"androidModeShortcuts":true,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":3,"keepConnected":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":2,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
    ] {
        fs::write(store.path(), contents).expect("write invalid preferences");

        assert_eq!(
            store.load().expect("load preferences"),
            Preferences::default()
        );
        assert!(
            !store.path().exists(),
            "invalid unreleased schema must not be migrated in place"
        );
    }
}

#[test]
fn preview_scale_accepts_only_50_through_150_percent() {
    assert!(PreviewScale::new(49).is_none());
    assert_eq!(PreviewScale::new(50).expect("minimum").percent(), 50);
    assert_eq!(PreviewScale::new(150).expect("maximum").percent(), 150);
    assert!(PreviewScale::new(151).is_none());
}
