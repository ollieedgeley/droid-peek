use std::{fs, os::unix::fs::PermissionsExt};

use omarchy_android_helper::persistence::{FileTrustedDeviceStore, TrustedDevice};
use tempfile::tempdir;

#[test]
fn saves_only_the_service_identity_in_private_state() {
    let directory = tempdir().expect("temporary state directory");
    let store = FileTrustedDeviceStore::new(directory.path().join("omarchy-android"));
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("valid service name");

    store.save(&device).expect("save trusted device");

    let state_directory = directory.path().join("omarchy-android");
    let state_path = state_directory.join("trusted-device.json");
    let contents = fs::read_to_string(&state_path).expect("read trusted-device state");
    assert_eq!(
        contents,
        "{\"version\":1,\"serviceName\":\"adb-14141FD6F00081-TnSdi9\"}\n"
    );
    assert!(!contents.contains("192.168"));
    assert!(!contents.contains("port"));
    assert!(!contents.contains("secret"));
    assert!(!contents.contains("code"));
    assert_eq!(
        fs::metadata(&state_directory)
            .expect("state directory metadata")
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(&state_path)
            .expect("state file metadata")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );

    let loaded = store
        .load()
        .expect("load trusted device")
        .expect("remembered device");
    assert_eq!(loaded.service_name(), device.service_name());
}

#[test]
fn missing_or_malformed_state_is_safely_unpaired() {
    let directory = tempdir().expect("temporary state directory");
    let store = FileTrustedDeviceStore::new(directory.path().join("omarchy-android"));
    assert!(store.load().expect("load missing state").is_none());

    fs::create_dir_all(store.directory()).expect("create state directory");
    fs::write(
        store.path(),
        b"{\"version\":1,\"serviceName\":\"10.0.0.2:37123\"}\n",
    )
    .expect("write malformed state");

    assert!(store.load().expect("load malformed state").is_none());
    assert!(!store.path().exists());
}

#[test]
fn remove_forgets_a_saved_device_and_is_idempotent() {
    let directory = tempdir().expect("temporary state directory");
    let store = FileTrustedDeviceStore::new(directory.path().join("omarchy-android"));
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("valid service name");
    store.save(&device).expect("save trusted device");

    store.remove().expect("remove trusted device");
    assert!(store.load().expect("load removed state").is_none());
    store.remove().expect("remove missing trusted device");
}

#[test]
fn device_identity_rejects_raw_or_unsafe_values() {
    for value in [
        "",
        "10.0.0.2:37123",
        "adb-device/../../secret",
        "adb-device\nsecret",
        "phone.local",
    ] {
        assert!(TrustedDevice::new(value).is_err(), "accepted {value:?}");
    }
}
