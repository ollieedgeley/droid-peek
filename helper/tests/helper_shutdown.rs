#![cfg(target_os = "linux")]

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
    let mut child = Command::new(env!("CARGO_BIN_EXE_droid-peek-helper"))
        .args(["--helper-epoch", "73001"])
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
        .write_all(b"{\"version\":11,\"type\":\"start-qr-pairing\",\"helperEpoch\":\"73001\"}\n")
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
    let runtime_directory = runtime_root.join("droid-peek");
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

#[test]
fn guardian_parent_process() {
    let Some(directory) = std::env::var_os("DROID_PEEK_GUARDIAN_TEST_DIR") else {
        return;
    };
    let directory = std::path::PathBuf::from(directory);
    let executables = directory.join("bin");
    let inherited_path = std::env::var("PATH").expect("PATH");
    let mut child = Command::new(env!("CARGO_BIN_EXE_droid-peek-helper"))
        .args([
            "--scrcpy-guardian",
            &std::process::id().to_string(),
            "--test-marker",
        ])
        .env(
            "PATH",
            format!("{}:{inherited_path}", executables.display()),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start scrcpy guardian");
    let pid_path = directory.join("scrcpy.pid");
    let deadline = Instant::now() + Duration::from_secs(2);
    while !pid_path.exists() && Instant::now() < deadline {
        if child.try_wait().expect("query scrcpy guardian").is_some() {
            panic!("scrcpy guardian exited before launching scrcpy");
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert!(pid_path.exists(), "fake scrcpy did not start");
    std::mem::forget(child);
}

#[test]
fn parent_death_guardian_stops_scrcpy_after_abrupt_helper_exit() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let executables = directory.path().join("bin");
    fs::create_dir(&executables).expect("fake executable directory");
    let pid_path = directory.path().join("scrcpy.pid");
    let scrcpy = executables.join("scrcpy");
    fs::write(
        &scrcpy,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$$\" > '{}'\nexec sleep 30\n",
            pid_path.display()
        ),
    )
    .expect("fake scrcpy executable");
    let mut permissions = fs::metadata(&scrcpy)
        .expect("fake scrcpy metadata")
        .permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&scrcpy, permissions).expect("make fake scrcpy executable private");

    let status = Command::new(std::env::current_exe().expect("current test executable"))
        .args(["--exact", "guardian_parent_process"])
        .env("DROID_PEEK_GUARDIAN_TEST_DIR", directory.path())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("run guardian parent process");
    assert!(status.success(), "guardian parent process failed");

    let scrcpy_pid = fs::read_to_string(&pid_path)
        .expect("fake scrcpy pid")
        .trim()
        .parse::<i32>()
        .expect("decimal scrcpy pid");
    let scrcpy_process = std::path::PathBuf::from(format!("/proc/{scrcpy_pid}"));
    let exit_deadline = Instant::now() + Duration::from_secs(2);
    while scrcpy_process.exists() && Instant::now() < exit_deadline {
        thread::sleep(Duration::from_millis(10));
    }
    if scrcpy_process.exists() {
        let _ = nix::sys::signal::kill(
            nix::unistd::Pid::from_raw(scrcpy_pid),
            nix::sys::signal::Signal::SIGKILL,
        );
        panic!("scrcpy survived abrupt helper-parent exit");
    }
}
