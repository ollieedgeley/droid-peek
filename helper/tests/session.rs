use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use omarchy_android_helper::{
    process::CancellationToken,
    session::{ScrcpySessionRunner, SessionExit, SessionFailure, SessionRunner},
};
use tempfile::tempdir;

fn fake_executable(directory: &Path, body: &str) -> PathBuf {
    let path = directory.join("fake-scrcpy");
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write fake scrcpy");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
        .expect("make fake scrcpy executable");
    path
}

#[test]
fn scrcpy_uses_a_private_headless_v4l2_command() {
    let directory = tempdir().expect("temporary directory");
    let arguments_file = directory.path().join("arguments");
    let executable = fake_executable(
        directory.path(),
        &format!("printf '%s\\n' \"$@\" > '{}'", arguments_file.display()),
    );
    let mut runner = ScrcpySessionRunner::new(executable, "/dev/video42", Duration::from_millis(2));
    let mut started = || {};

    assert_eq!(
        runner.run("192.0.2.20:38100", &CancellationToken::new(), &mut started,),
        Ok(SessionExit::Ended)
    );
    assert_eq!(
        fs::read_to_string(arguments_file).expect("captured arguments"),
        concat!(
            "--serial=192.0.2.20:38100\n",
            "--no-window\n",
            "--no-audio\n",
            "--no-control\n",
            "--v4l2-sink=/dev/video42\n",
        )
    );
}

#[test]
fn scrcpy_reports_start_then_stops_its_child_on_cancellation() {
    let directory = tempdir().expect("temporary directory");
    let executable = fake_executable(directory.path(), "exec sleep 30");
    let runner = Arc::new(Mutex::new(ScrcpySessionRunner::new(
        executable,
        "/dev/video42",
        Duration::from_millis(2),
    )));
    let cancellation = CancellationToken::new();
    let worker_runner = Arc::clone(&runner);
    let worker_cancellation = cancellation.clone();
    let started = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let worker_started = Arc::clone(&started);

    let worker = thread::spawn(move || {
        worker_runner.lock().expect("runner lock").run(
            "192.0.2.20:38100",
            &worker_cancellation,
            &mut || worker_started.store(true, std::sync::atomic::Ordering::Release),
        )
    });
    while !started.load(std::sync::atomic::Ordering::Acquire) {
        thread::sleep(Duration::from_millis(2));
    }
    cancellation.cancel();

    assert_eq!(
        worker.join().expect("session worker"),
        Ok(SessionExit::Stopped)
    );
}

#[test]
fn scrcpy_failures_are_fixed_categories() {
    let directory = tempdir().expect("temporary directory");
    let executable = fake_executable(directory.path(), "exit 1");
    let mut runner = ScrcpySessionRunner::new(executable, "/dev/video42", Duration::from_millis(2));

    assert_eq!(
        runner.run("192.0.2.20:38100", &CancellationToken::new(), &mut || {},),
        Err(SessionFailure::Disconnected)
    );
    let mut missing = ScrcpySessionRunner::new(
        directory.path().join("missing-scrcpy"),
        "/dev/video42",
        Duration::from_millis(2),
    );
    assert_eq!(
        missing.run("192.0.2.20:38100", &CancellationToken::new(), &mut || {},),
        Err(SessionFailure::DependencyUnavailable)
    );
}
