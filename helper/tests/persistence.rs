use std::{env, ffi::OsStr, fs, os::unix::fs::PermissionsExt, path::PathBuf, sync::Mutex};

use droid_peek_helper::persistence::{
    FileTrustedDeviceStore, TrustedDevice, default_state_directory,
};
use tempfile::tempdir;

static STATE_ENV_LOCK: Mutex<()> = Mutex::new(());

fn set_optional_env(key: &str, value: Option<&OsStr>) {
    // SAFETY: callers hold STATE_ENV_LOCK for the whole mutation window
    // and restore the previous values before releasing it.
    unsafe {
        match value {
            Some(value) => env::set_var(key, value),
            None => env::remove_var(key),
        }
    }
}

fn with_state_env<T>(
    xdg_state_home: Option<&str>,
    home: Option<&str>,
    body: impl FnOnce() -> T,
) -> T {
    let _lock = STATE_ENV_LOCK.lock().expect("state env lock");
    let previous_state_home = env::var_os("XDG_STATE_HOME");
    let previous_home = env::var_os("HOME");
    set_optional_env("XDG_STATE_HOME", xdg_state_home.map(OsStr::new));
    set_optional_env("HOME", home.map(OsStr::new));
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body));
    set_optional_env("XDG_STATE_HOME", previous_state_home.as_deref());
    set_optional_env("HOME", previous_home.as_deref());
    match result {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

#[test]
fn saves_only_the_service_identity_in_private_state() {
    let directory = tempdir().expect("temporary state directory");
    let store = FileTrustedDeviceStore::new(directory.path().join("droid-peek"));
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("valid service name");

    store.save(&device).expect("save trusted device");

    let state_directory = directory.path().join("droid-peek");
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
    let store = FileTrustedDeviceStore::new(directory.path().join("droid-peek"));
    assert!(store.load().expect("load missing state").is_none());

    fs::create_dir_all(directory.path().join("droid-peek")).expect("create state directory");
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
    let store = FileTrustedDeviceStore::new(directory.path().join("droid-peek"));
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

#[test]
fn empty_xdg_state_home_falls_back_to_home_local_state() {
    let directory = with_state_env(
        Some(""),
        Some("/tmp/omarchy-ar-125-home"),
        default_state_directory,
    );
    assert_eq!(
        directory,
        Some(PathBuf::from(
            "/tmp/omarchy-ar-125-home/.local/state/droid-peek"
        ))
    );
}

#[test]
fn empty_xdg_state_home_and_home_yield_no_state_directory() {
    let directory = with_state_env(Some(""), Some(""), default_state_directory);
    assert_eq!(directory, None);
}
