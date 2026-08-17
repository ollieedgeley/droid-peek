use std::{fs, os::unix::fs::PermissionsExt, time::SystemTime};

use omarchy_android_helper::action_results::ActionResultStore;

fn test_directory(name: &str) -> std::path::PathBuf {
    let nonce = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .expect("time after epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "omarchy-android-{name}-{}-{nonce}",
        std::process::id()
    ))
}

#[test]
fn publishes_private_atomic_correlated_results() {
    let root = test_directory("action-result");
    let store = ActionResultStore::new(&root).expect("create result store");

    store
        .publish("request-123", true)
        .expect("publish handled result");

    let path = root.join("action-results/request-123");
    assert_eq!(fs::read_to_string(&path).expect("read result"), "true\n");
    assert_eq!(
        fs::metadata(&path)
            .expect("result metadata")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert!(store.publish("request-123", false).is_err());

    fs::remove_dir_all(root).expect("remove test directory");
}

#[test]
fn rejects_unsafe_request_ids_and_removes_stale_results() {
    let root = test_directory("action-result-validation");
    let first = ActionResultStore::new(&root).expect("create first store");
    first
        .publish("stale-1", false)
        .expect("publish stale result");

    let store = ActionResultStore::new(&root).expect("recreate store");
    assert!(!root.join("action-results/stale-1").exists());

    for request_id in ["", "../escape", "with/slash", "with space", &"x".repeat(65)] {
        assert!(store.publish(request_id, true).is_err());
    }

    fs::remove_dir_all(root).expect("remove test directory");
}
