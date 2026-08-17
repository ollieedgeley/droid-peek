#![cfg(unix)]

use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

#[test]
fn stdin_eof_stops_pairing_child_and_removes_qr_artifact() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let executables = directory.path().join("bin");
    fs::create_dir(&executables).expect("fake executable directory");
    let pid_path = directory.path().join("avahi.pid");
    let avahi = executables.join("avahi-browse");
    fs::write(
        &avahi,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$$\" > '{}'\nexec sleep 30\n",
            pid_path.display()
        ),
    )
    .expect("fake Avahi executable");
    let mut permissions = fs::metadata(&avahi)
        .expect("fake Avahi metadata")
        .permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&avahi, permissions).expect("make fake Avahi executable private");

    let runtime_root = directory.path().join("runtime-root");
    let state_root = directory.path().join("state-root");
    fs::create_dir(&runtime_root).expect("runtime root");
    fs::create_dir(&state_root).expect("state root");
    let inherited_path = std::env::var("PATH").expect("PATH");
    let mut child = Command::new(env!("CARGO_BIN_EXE_omarchy-android-helper"))
        .env(
            "PATH",
            format!("{}:{inherited_path}", executables.display()),
        )
        .env("XDG_RUNTIME_DIR", &runtime_root)
        .env("XDG_STATE_HOME", &state_root)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start helper");
    let mut stdin = child.stdin.take().expect("helper stdin");
    stdin
        .write_all(b"{\"version\":10,\"type\":\"start-qr-pairing\"}\n")
        .expect("start QR pairing");
    stdin.flush().expect("flush helper command");

    let child_started_deadline = Instant::now() + Duration::from_secs(2);
    while !pid_path.exists() && Instant::now() < child_started_deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(pid_path.exists(), "fake Avahi child did not start");
    let avahi_pid = fs::read_to_string(&pid_path).expect("Avahi pid");

    drop(stdin);
    let exit_deadline = Instant::now() + Duration::from_secs(2);
    let status = loop {
        if let Some(status) = child.try_wait().expect("query helper status") {
            break status;
        }
        if Instant::now() >= exit_deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("helper did not stop after stdin EOF");
        }
        thread::sleep(Duration::from_millis(10));
    };

    assert!(status.success());
    let avahi_process = std::path::PathBuf::from(format!("/proc/{}", avahi_pid.trim()));
    assert!(
        !avahi_process.exists(),
        "fake Avahi child survived helper shutdown"
    );
    let runtime_directory = runtime_root.join("omarchy-android");
    assert!(
        fs::read_dir(runtime_directory)
            .expect("runtime directory")
            .all(|entry| entry
                .expect("runtime entry")
                .path()
                .extension()
                .is_none_or(|extension| extension != "svg")),
        "QR artifact survived helper shutdown"
    );
}
