use std::process::Command;

#[test]
fn helper_version_prints_package_version_and_exits_zero() {
    let output = Command::new(env!("CARGO_BIN_EXE_droid-peek-helper"))
        .arg("--version")
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("XDG_STATE_HOME")
        .env_remove("HOME")
        .output()
        .expect("run helper --version");

    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).expect("UTF-8 version"),
        format!("{}\n", env!("CARGO_PKG_VERSION"))
    );
    assert!(output.stderr.is_empty());
}
