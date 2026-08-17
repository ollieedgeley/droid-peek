use std::{fs, os::unix::fs::PermissionsExt};

use omarchy_android_helper::preferences::{
    FilePreferenceStore, Preferences, PreviewScale, QuickAction, VideoQuality,
};
use tempfile::tempdir;

#[test]
fn defaults_disable_android_mode_shortcuts_and_command_passthrough() {
    assert_eq!(
        Preferences::default(),
        Preferences {
            keep_connected: false,
            android_mode_shortcuts: false,
            command_passthrough: false,
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
    assert!(!Preferences::default().command_passthrough);
}

#[test]
fn preferences_round_trip_in_private_versioned_state() {
    let directory = tempdir().expect("temporary state directory");
    let store = FilePreferenceStore::new(directory.path().join("omarchy-android"));
    let preferences = Preferences {
        keep_connected: true,
        android_mode_shortcuts: true,
        command_passthrough: true,
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
        "{\"version\":5,\"keepConnected\":true,\"androidModeShortcuts\":true,\"commandPassthrough\":true,\"previewScale\":150,\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n"
    );
    assert_eq!(
        fs::metadata(store.path())
            .expect("preference file metadata")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(store.directory())
            .expect("preference directory metadata")
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
}

#[test]
fn malformed_or_incomplete_preferences_are_removed_and_reset_to_defaults() {
    let directory = tempdir().expect("temporary state directory");
    let store = FilePreferenceStore::new(directory.path().join("omarchy-android"));
    fs::create_dir_all(store.directory()).expect("create state directory");

    for contents in [
        r#"{"version":5,"keepConnected":false,"androidModeShortcuts":false,"commandPassthrough":false,"previewScale":151,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":5,"keepConnected":false,"androidModeShortcuts":false,"commandPassthrough":"yes","previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":5,"keepConnected":false,"androidModeShortcuts":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
    ] {
        fs::write(store.path(), contents).expect("write invalid preferences");

        assert_eq!(
            store.load().expect("load preferences"),
            Preferences::default()
        );
        assert!(!store.path().exists());
    }
}

#[test]
fn version_four_preferences_migrate_without_enabling_command_passthrough() {
    let directory = tempdir().expect("temporary state directory");
    let store = FilePreferenceStore::new(directory.path().join("omarchy-android"));
    fs::create_dir_all(store.directory()).expect("create state directory");
    fs::write(
        store.path(),
        b"{\"version\":4,\"keepConnected\":true,\"androidModeShortcuts\":true,\"previewScale\":125,\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n",
    )
    .expect("write version-four preferences");

    assert_eq!(
        store.load().expect("migrate preferences"),
        Preferences {
            keep_connected: true,
            android_mode_shortcuts: true,
            command_passthrough: false,
            preview_scale: PreviewScale::new(125).expect("valid preview scale"),
            video_quality: VideoQuality::Low,
            quick_actions: [
                QuickAction::Home,
                QuickAction::RecentApps,
                QuickAction::Back,
            ],
        }
    );
    assert_eq!(
        fs::read_to_string(store.path()).expect("read migrated preferences"),
        "{\"version\":5,\"keepConnected\":true,\"androidModeShortcuts\":true,\"commandPassthrough\":false,\"previewScale\":125,\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n"
    );
}

#[test]
fn version_three_preferences_migrate_in_place_without_enabling_android_mode_shortcuts() {
    let directory = tempdir().expect("temporary state directory");
    let store = FilePreferenceStore::new(directory.path().join("omarchy-android"));
    fs::create_dir_all(store.directory()).expect("create state directory");
    fs::write(
        store.path(),
        b"{\"version\":3,\"keepConnected\":true,\"previewScale\":125,\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n",
    )
    .expect("write version-three preferences");

    assert_eq!(
        store.load().expect("migrate preferences"),
        Preferences {
            keep_connected: true,
            android_mode_shortcuts: false,
            command_passthrough: false,
            preview_scale: PreviewScale::new(125).expect("valid preview scale"),
            video_quality: VideoQuality::Low,
            quick_actions: [
                QuickAction::Home,
                QuickAction::RecentApps,
                QuickAction::Back,
            ],
        }
    );
    assert_eq!(
        fs::read_to_string(store.path()).expect("read migrated preferences"),
        "{\"version\":5,\"keepConnected\":true,\"androidModeShortcuts\":false,\"commandPassthrough\":false,\"previewScale\":125,\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n"
    );
    assert!(!store.directory().join(".preferences.json.tmp").exists());
}

#[test]
fn version_two_render_preferences_migrate_without_enabling_keep_connected() {
    let directory = tempdir().expect("temporary state directory");
    let state_directory = directory.path().join("omarchy-android");
    let store = FilePreferenceStore::new(&state_directory);
    let legacy_path = state_directory.join("render-preferences.json");
    fs::create_dir_all(&state_directory).expect("create state directory");
    fs::write(
        &legacy_path,
        b"{\"version\":2,\"previewScale\":150,\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n",
    )
    .expect("write legacy preferences");

    assert_eq!(
        store.load().expect("migrate preferences"),
        Preferences {
            keep_connected: false,
            android_mode_shortcuts: false,
            command_passthrough: false,
            preview_scale: PreviewScale::new(150).expect("valid preview scale"),
            video_quality: VideoQuality::Low,
            quick_actions: [
                QuickAction::Home,
                QuickAction::RecentApps,
                QuickAction::Back,
            ],
        }
    );
    assert!(store.path().exists());
    assert!(!legacy_path.exists());
    assert_eq!(
        fs::read_to_string(store.path()).expect("read migrated preferences"),
        "{\"version\":5,\"keepConnected\":false,\"androidModeShortcuts\":false,\"commandPassthrough\":false,\"previewScale\":150,\"videoQuality\":\"low\",\"quickActions\":[\"home\",\"recent-apps\",\"back\"]}\n"
    );
}

#[test]
fn preview_scale_accepts_only_50_through_150_percent() {
    assert!(PreviewScale::new(49).is_none());
    assert_eq!(PreviewScale::new(50).expect("minimum").percent(), 50);
    assert_eq!(PreviewScale::new(150).expect("maximum").percent(), 150);
    assert!(PreviewScale::new(151).is_none());
}
