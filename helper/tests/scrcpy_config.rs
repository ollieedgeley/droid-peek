use std::{fs, os::unix::fs::PermissionsExt, process::Command};

use omarchy_android_helper::scrcpy_config::{
    FileScrcpyConfigStore, ScrcpyConfigError, ScrcpyConfiguration, decode_arguments_envelope,
};
use tempfile::tempdir;

#[test]
fn validates_supported_arguments_and_derives_stable_state() {
    let first = ScrcpyConfiguration::validated(vec![
        "--keep-active".to_owned(),
        "--turn-screen-off".to_owned(),
        "--window-title=Téléphone".to_owned(),
    ])
    .expect("valid scrcpy arguments");
    let same = ScrcpyConfiguration::validated(first.arguments().to_vec())
        .expect("same valid scrcpy arguments");
    let changed = ScrcpyConfiguration::validated(vec!["--keep-active".to_owned()])
        .expect("changed valid scrcpy arguments");

    assert_eq!(first.arguments()[0], "--keep-active");
    assert!(first.screen_off_requested());
    assert_eq!(first.revision(), same.revision());
    assert_ne!(first.revision(), changed.revision());
    assert!(
        first
            .revision()
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    );
    assert_eq!(
        first.effective_arguments(false),
        [
            "--keep-active".to_owned(),
            "--window-title=Téléphone".to_owned()
        ]
    );
    assert_eq!(first.effective_arguments(true), first.arguments());
}

#[test]
fn rejects_arguments_that_can_break_plugin_invariants() {
    for arguments in [
        vec!["--serial=device"],
        vec!["--serial", "device"],
        vec!["-s", "device"],
        vec!["--no-window"],
        vec!["--window"],
        vec!["--video-source=camera"],
        vec!["--new-display"],
        vec!["--v4l2-sink=/dev/video9"],
        vec!["--no-video"],
        vec!["--no-control=false"],
        vec!["--max-size=720"],
        vec!["--audio-codec=opus"],
    ] {
        let arguments = arguments.into_iter().map(str::to_owned).collect();
        assert!(ScrcpyConfiguration::validated(arguments).is_err());
    }
}

#[test]
fn rejects_malformed_and_oversized_argument_lists() {
    assert_eq!(
        ScrcpyConfiguration::validated(vec!["keep-awake".to_owned()]),
        Err(ScrcpyConfigError::InvalidArgument)
    );
    assert_eq!(
        ScrcpyConfiguration::validated(vec!["--keep\nawake".to_owned()]),
        Err(ScrcpyConfigError::InvalidArgument)
    );
    assert_eq!(
        ScrcpyConfiguration::validated(vec!["--x".to_owned(); 33]),
        Err(ScrcpyConfigError::TooManyArguments)
    );
    assert_eq!(
        ScrcpyConfiguration::validated(vec![format!("--x={}", "a".repeat(510))]),
        Err(ScrcpyConfigError::InvalidArgument)
    );
}

#[test]
fn private_snapshot_round_trips_and_empty_configuration_removes_it() {
    let directory = tempdir().expect("temporary state directory");
    let store = FileScrcpyConfigStore::new(directory.path());
    let configuration = ScrcpyConfiguration::validated(vec![
        "--keep-active".to_owned(),
        "--turn-screen-off".to_owned(),
    ])
    .expect("valid configuration");

    store.store(&configuration).expect("store configuration");
    assert_eq!(store.load().expect("load configuration"), configuration);
    let metadata =
        fs::metadata(directory.path().join("scrcpy-args.json")).expect("snapshot metadata");
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);

    let empty = ScrcpyConfiguration::validated(Vec::new()).expect("empty configuration");
    store.store(&empty).expect("clear configuration");
    assert_eq!(store.load().expect("load cleared configuration"), empty);
    assert!(!directory.path().join("scrcpy-args.json").exists());
}

#[test]
fn rejects_a_tampered_snapshot() {
    let directory = tempdir().expect("temporary state directory");
    fs::write(
        directory.path().join("scrcpy-args.json"),
        r#"{"arguments":["--serial=device"],"revision":"forged"}"#,
    )
    .expect("write tampered snapshot");
    let store = FileScrcpyConfigStore::new(directory.path());

    assert!(store.load().is_err());
}

#[test]
fn decodes_base64url_json_without_exposing_arguments_to_shell_syntax() {
    assert_eq!(
        decode_arguments_envelope("WyItLWtlZXAtYWN0aXZlIiwiLS13aW5kb3ctdGl0bGU9VMOpbMOpcGhvbmUiXQ")
            .expect("valid envelope"),
        vec![
            "--keep-active".to_owned(),
            "--window-title=Téléphone".to_owned()
        ]
    );
    assert!(decode_arguments_envelope("not+base64").is_err());
    assert!(decode_arguments_envelope("e30").is_err());
}

#[test]
fn helper_store_subcommand_persists_validated_arguments_and_prints_only_revision() {
    let state_root = tempdir().expect("temporary state root");
    let output = Command::new(env!("CARGO_BIN_EXE_omarchy-android-helper"))
        .args([
            "store-scrcpy-args",
            "WyItLWtlZXAtYWN0aXZlIiwiLS10dXJuLXNjcmVlbi1vZmYiXQ",
        ])
        .env("XDG_STATE_HOME", state_root.path())
        .env_remove("HOME")
        .output()
        .expect("run helper store subcommand");

    assert!(output.status.success());
    let revision = String::from_utf8(output.stdout).expect("UTF-8 revision");
    assert!(revision.trim().bytes().all(|byte| byte.is_ascii_hexdigit()));
    assert!(output.stderr.is_empty());
    let stored = FileScrcpyConfigStore::new(state_root.path().join("omarchy-android"))
        .load()
        .expect("stored configuration");
    assert_eq!(
        stored.arguments(),
        ["--keep-active".to_owned(), "--turn-screen-off".to_owned()]
    );
    assert_eq!(revision.trim(), stored.revision());
}
