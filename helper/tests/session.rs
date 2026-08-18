use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use omarchy_android_helper::{
    preferences::VideoQuality,
    process::CancellationToken,
    session::{
        PhysicalDisplayProbe, PhysicalDisplaySize, ScrcpySessionRunner, SessionExit,
        SessionFailure, SessionRunner,
    },
};
use tempfile::tempdir;

static PROCESS_TEST_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Copy)]
struct NoDisplayProbe;

impl PhysicalDisplayProbe for NoDisplayProbe {
    fn probe(
        &mut self,
        _target: &str,
        _cancellation: &CancellationToken,
    ) -> Option<PhysicalDisplaySize> {
        None
    }
}

fn fake_executable(directory: &Path, body: &str) -> PathBuf {
    let path = directory.join("fake-scrcpy");
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write fake scrcpy");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
        .expect("make fake scrcpy executable");
    path
}

fn writable_sink(directory: &Path) -> PathBuf {
    let sink = directory.join("video42");
    fs::write(&sink, []).expect("create writable video sink");
    sink
}

#[test]
fn scrcpy_uses_a_private_headless_v4l2_command() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempdir().expect("temporary directory");
    let arguments_file = directory.path().join("arguments");
    let executable = fake_executable(
        directory.path(),
        &format!("printf '%s\\n' \"$@\" > '{}'", arguments_file.display()),
    );
    let sink = writable_sink(directory.path());
    let mut runner =
        ScrcpySessionRunner::new_with_test_sink(executable, &sink, Duration::from_millis(2))
            .with_display_probe(NoDisplayProbe);
    let mut started = |_| {};

    assert_eq!(
        runner.run("192.0.2.20:38100", &CancellationToken::new(), &mut started,),
        Ok(SessionExit::Ended)
    );
    assert_eq!(
        fs::read_to_string(arguments_file).expect("captured arguments"),
        format!(
            concat!(
                "--serial=192.0.2.20:38100\n",
                "--no-window\n",
                "--no-audio\n",
                "--no-control\n",
                "--v4l2-sink={}\n",
                "--max-size=0\n",
                "--video-bit-rate=16M\n",
                "--max-fps=60\n",
            ),
            sink.display()
        )
    );
}

#[test]
fn scrcpy_starts_after_the_validation_handle_is_closed() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempdir().expect("temporary directory");
    let sink = writable_sink(directory.path());
    let executable = fake_executable(
        directory.path(),
        &format!(
            "for fd in /proc/$PPID/fd/*; do\n    if [ \"$fd\" -ef '{}' ]; then\n        exit 42\n    fi\ndone\nexit 0",
            sink.display()
        ),
    );
    let mut runner =
        ScrcpySessionRunner::new_with_test_sink(executable, &sink, Duration::from_millis(2))
            .with_display_probe(NoDisplayProbe);

    assert_eq!(
        runner.run("192.0.2.20:38100", &CancellationToken::new(), &mut |_| {}),
        Ok(SessionExit::Ended)
    );
}

#[test]
fn scrcpy_applies_the_selected_video_quality_profile() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let expected = [
        (
            VideoQuality::Low,
            ["--max-size=720", "--video-bit-rate=4M", "--max-fps=30"],
        ),
        (
            VideoQuality::Medium,
            ["--max-size=1080", "--video-bit-rate=8M", "--max-fps=60"],
        ),
        (
            VideoQuality::High,
            ["--max-size=0", "--video-bit-rate=16M", "--max-fps=60"],
        ),
    ];

    for (quality, profile) in expected {
        let directory = tempdir().expect("temporary directory");
        let arguments_file = directory.path().join("arguments");
        let executable = fake_executable(
            directory.path(),
            &format!("printf '%s\\n' \"$@\" > '{}'", arguments_file.display()),
        );
        let mut runner = ScrcpySessionRunner::new_with_test_sink(
            executable,
            writable_sink(directory.path()),
            Duration::from_millis(2),
        )
        .with_display_probe(NoDisplayProbe);
        runner.set_quality(quality);

        assert_eq!(
            runner.run("192.0.2.20:38100", &CancellationToken::new(), &mut |_| {}),
            Ok(SessionExit::Ended)
        );
        let arguments = fs::read_to_string(arguments_file).expect("captured arguments");
        for argument in profile {
            assert!(arguments.lines().any(|line| line == argument));
        }
    }
}

#[test]
fn scrcpy_reports_start_then_stops_its_child_on_cancellation() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempdir().expect("temporary directory");
    let readiness_file = directory.path().join("state");
    fs::write(&readiness_file, "capture\n").expect("write ready sink state");
    let executable = fake_executable(directory.path(), "exec sleep 30");
    let runner = Arc::new(Mutex::new(
        ScrcpySessionRunner::new_with_test_sink(
            executable,
            writable_sink(directory.path()),
            Duration::from_millis(2),
        )
        .with_readiness_path(&readiness_file)
        .with_display_probe(NoDisplayProbe),
    ));
    let cancellation = CancellationToken::new();
    let worker_runner = Arc::clone(&runner);
    let worker_cancellation = cancellation.clone();
    let (started_tx, started_rx) = std::sync::mpsc::channel();

    let worker = thread::spawn(move || {
        worker_runner.lock().expect("runner lock").run(
            "192.0.2.20:38100",
            &worker_cancellation,
            &mut |_| started_tx.send(()).expect("signal session start"),
        )
    });
    if let Err(error) = started_rx.recv_timeout(Duration::from_secs(1)) {
        cancellation.cancel();
        let session_result = worker.join().expect("session worker");
        panic!("session did not start: {error}; runner returned {session_result:?}");
    }
    cancellation.cancel();

    assert_eq!(
        worker.join().expect("session worker"),
        Ok(SessionExit::Stopped)
    );
}

#[test]
fn scrcpy_reports_started_only_after_the_sink_is_capture_ready() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempdir().expect("temporary directory");
    let readiness_file = directory.path().join("state");
    fs::write(&readiness_file, "output\n").expect("write initial sink state");
    let executable = fake_executable(directory.path(), "exec sleep 30");
    let runner = Arc::new(Mutex::new(
        ScrcpySessionRunner::new_with_test_sink(
            executable,
            writable_sink(directory.path()),
            Duration::from_millis(2),
        )
        .with_readiness_path(&readiness_file)
        .with_display_probe(NoDisplayProbe),
    ));
    let cancellation = CancellationToken::new();
    let worker_runner = Arc::clone(&runner);
    let worker_cancellation = cancellation.clone();
    let (started_tx, started_rx) = std::sync::mpsc::channel();

    let worker = thread::spawn(move || {
        worker_runner.lock().expect("runner lock").run(
            "192.0.2.20:38100",
            &worker_cancellation,
            &mut |_| started_tx.send(()).expect("signal session start"),
        )
    });
    assert!(started_rx.recv_timeout(Duration::from_millis(20)).is_err());

    fs::write(&readiness_file, "capture\n").expect("mark sink capture-ready");
    started_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("session start after sink readiness");
    cancellation.cancel();

    assert_eq!(
        worker.join().expect("session worker"),
        Ok(SessionExit::Stopped)
    );
}

#[test]
fn scrcpy_rejects_an_unwritable_sink_before_spawning() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempdir().expect("temporary directory");
    let spawned = directory.path().join("spawned");
    let executable = fake_executable(directory.path(), &format!("touch '{}'", spawned.display()));
    let mut runner = ScrcpySessionRunner::new_with_test_sink(
        executable,
        directory.path(),
        Duration::from_millis(2),
    )
    .with_display_probe(NoDisplayProbe);

    assert_eq!(
        runner.run("192.0.2.20:38100", &CancellationToken::new(), &mut |_| {}),
        Err(SessionFailure::DependencyUnavailable)
    );
    assert!(!spawned.exists());
}

#[test]
fn scrcpy_failures_are_fixed_categories() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempdir().expect("temporary directory");
    let executable = fake_executable(directory.path(), "exit 1");
    let sink = writable_sink(directory.path());
    let mut runner =
        ScrcpySessionRunner::new_with_test_sink(executable, &sink, Duration::from_millis(2))
            .with_display_probe(NoDisplayProbe);

    assert_eq!(
        runner.run("192.0.2.20:38100", &CancellationToken::new(), &mut |_| {},),
        Err(SessionFailure::Disconnected)
    );
    let mut missing = ScrcpySessionRunner::new_with_test_sink(
        directory.path().join("missing-scrcpy"),
        sink,
        Duration::from_millis(2),
    );
    missing = missing.with_display_probe(NoDisplayProbe);
    assert_eq!(
        missing.run("192.0.2.20:38100", &CancellationToken::new(), &mut |_| {},),
        Err(SessionFailure::DependencyUnavailable)
    );
}

#[test]
fn scrcpy_appends_validated_user_arguments_after_owned_arguments() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempdir().expect("temporary directory");
    let arguments_file = directory.path().join("arguments");
    let executable = fake_executable(
        directory.path(),
        &format!("printf '%s\\n' \"$@\" > '{}'", arguments_file.display()),
    );
    let mut runner: Box<dyn SessionRunner> = Box::new(
        ScrcpySessionRunner::new_with_test_sink(
            executable,
            writable_sink(directory.path()),
            Duration::from_millis(2),
        )
        .with_display_probe(NoDisplayProbe),
    );
    runner.set_quality(VideoQuality::Low);
    runner.set_scrcpy_arguments(vec![
        "--keep-active".to_owned(),
        "--stay-awake".to_owned(),
        "--window-title=Téléphone".to_owned(),
    ]);

    assert_eq!(
        runner.run("192.0.2.20:38100", &CancellationToken::new(), &mut |_| {}),
        Ok(SessionExit::Ended)
    );
    let arguments = fs::read_to_string(arguments_file).expect("captured arguments");
    let lines = arguments.lines().collect::<Vec<_>>();
    assert_eq!(
        &lines[lines.len() - 3..],
        ["--keep-active", "--stay-awake", "--window-title=Téléphone"]
    );
    assert!(lines.contains(&"--max-size=720"));
    assert!(lines.contains(&"--video-bit-rate=4M"));
    assert!(!lines.contains(&"--no-control"));
}
