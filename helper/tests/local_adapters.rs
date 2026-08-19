#![cfg(unix)]

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};

use omarchy_android_helper::{
    process::{
        ActionExecutionFailure, AdbCommandRunner, CancellationToken, CommandFailure,
        CommandRequest, CommandRunner,
    },
    wireless::{AvahiDiscovery, DiscoveryFailure, PairingEndpoint, WirelessDiscovery},
};
use zeroize::Zeroizing;

static PROCESS_TEST_LOCK: Mutex<()> = Mutex::new(());

fn executable(directory: &Path, name: &str, body: &str) -> PathBuf {
    let path = directory.join(name);
    fs::write(&path, format!("#!/usr/bin/env bash\nset -eu\n{body}\n"))
        .expect("write fake executable");
    let mut permissions = fs::metadata(&path).expect("fake metadata").permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&path, permissions).expect("make fake executable private");
    path
}

#[test]
fn adb_runner_uses_separated_arguments_private_stdin_and_discards_output() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let arguments_file = directory.path().join("arguments");
    let stdin_file = directory.path().join("stdin");
    let fake_adb = executable(
        directory.path(),
        "adb",
        &format!(
            "printf '%s\\n' \"$@\" > '{}'\ncat > '{}'\nprintf 'raw endpoint and secret'\nprintf 'raw failure' >&2",
            arguments_file.display(),
            stdin_file.display()
        ),
    );
    let mut runner = AdbCommandRunner::new(fake_adb, Duration::from_millis(2));

    let output = runner
        .run(
            CommandRequest::new(
                "adb",
                vec!["pair".to_owned(), "phone.local:37000".to_owned()],
            )
            .with_stdin(Zeroizing::new("temporary-secret\n".to_owned())),
            &CancellationToken::new(),
        )
        .expect("fake ADB command");

    assert!(output.succeeded);
    assert_eq!(
        fs::read_to_string(arguments_file).expect("recorded arguments"),
        "pair\nphone.local:37000\n"
    );
    assert_eq!(
        fs::read_to_string(stdin_file).expect("recorded standard input"),
        "temporary-secret\n"
    );
}

#[test]
fn adb_runner_classifies_only_bounded_phone_target_output() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    for (name, body, expected) in [
        (
            "absent-adb",
            "printf \"error: device 'selected-device' not found\" >&2\nexit 1",
            ActionExecutionFailure::Disconnected,
        ),
        (
            "offline-adb",
            "printf 'error: device offline' >&2\nexit 1",
            ActionExecutionFailure::Disconnected,
        ),
        (
            "unauthorized-adb",
            "printf 'error: device unauthorized' >&2\nexit 1",
            ActionExecutionFailure::Unauthorized,
        ),
    ] {
        let fake_adb = executable(directory.path(), name, body);
        let mut runner = AdbCommandRunner::new(fake_adb, Duration::from_millis(2));
        let result = runner.run_phone_target(
            CommandRequest::new(
                "adb",
                vec![
                    "-s".to_owned(),
                    "selected-device".to_owned(),
                    "shell".to_owned(),
                    "input".to_owned(),
                    "keyevent".to_owned(),
                    "KEYCODE_HOME".to_owned(),
                ],
            ),
            &CancellationToken::new(),
        );
        assert_eq!(result, Err(expected));
        assert!(!format!("{result:?}").contains("selected-device"));
    }

    let bounded_adb = executable(
        directory.path(),
        "bounded-adb",
        "for ((i = 0; i < 9000; i++)); do printf x >&2; done\nprintf 'device unauthorized' >&2\nexit 1",
    );
    let mut runner = AdbCommandRunner::new(bounded_adb, Duration::from_millis(2));
    assert_eq!(
        runner.run_phone_target(
            CommandRequest::new(
                "adb",
                vec![
                    "-s".to_owned(),
                    "selected-device".to_owned(),
                    "shell".to_owned(),
                    "input".to_owned(),
                    "keyevent".to_owned(),
                    "KEYCODE_HOME".to_owned(),
                ],
            ),
            &CancellationToken::new(),
        ),
        Ok(omarchy_android_helper::process::CommandOutput { succeeded: false })
    );
}

#[test]
fn adb_runner_classifies_monkey_abort_as_an_action_failure() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");

    fn monkey_request() -> CommandRequest {
        CommandRequest::new(
            "adb",
            vec![
                "-s".to_owned(),
                "selected-device".to_owned(),
                "shell".to_owned(),
                "monkey".to_owned(),
                "-p".to_owned(),
                "com.example.missing".to_owned(),
                "-c".to_owned(),
                "android.intent.category.LAUNCHER".to_owned(),
                "1".to_owned(),
            ],
        )
    }

    for (name, body) in [
        (
            "monkey-abort-252",
            "printf '** No activities found to run, monkey aborted.\\n'\nexit 252",
        ),
        (
            "monkey-abort-zero",
            "printf '** No activities found to run, monkey aborted.\\n'\nexit 0",
        ),
    ] {
        let fake_adb = executable(directory.path(), name, body);
        let mut runner = AdbCommandRunner::new(fake_adb, Duration::from_millis(2));
        let result = runner.run_phone_target(monkey_request(), &CancellationToken::new());
        assert_eq!(
            result,
            Ok(omarchy_android_helper::process::CommandOutput { succeeded: false }),
            "{name} must be an action-only failure"
        );
        assert!(
            !format!("{result:?}").contains("No activities found"),
            "{name} must not expose Monkey text"
        );
    }

    let success_adb = executable(
        directory.path(),
        "monkey-success",
        "printf 'Events injected: 1\\n'\nexit 0",
    );
    let mut runner = AdbCommandRunner::new(success_adb, Duration::from_millis(2));
    assert_eq!(
        runner.run_phone_target(monkey_request(), &CancellationToken::new()),
        Ok(omarchy_android_helper::process::CommandOutput { succeeded: true })
    );

    let unauthorized_abort = executable(
        directory.path(),
        "monkey-unauthorized",
        "printf '** No activities found to run, monkey aborted.\\n'\nprintf 'error: device unauthorized' >&2\nexit 1",
    );
    let mut runner = AdbCommandRunner::new(unauthorized_abort, Duration::from_millis(2));
    assert_eq!(
        runner.run_phone_target(monkey_request(), &CancellationToken::new()),
        Err(ActionExecutionFailure::Unauthorized)
    );
}
#[test]
fn adb_runner_preserves_generic_nonzero_results_for_other_commands_and_actions() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let ordinary_adb = executable(
        directory.path(),
        "ordinary-adb",
        "printf 'synthetic ordinary failure with private detail' >&2\nexit 1",
    );
    let mut runner = AdbCommandRunner::new(ordinary_adb, Duration::from_millis(2));

    let result = runner.run_phone_target(
        CommandRequest::new(
            "adb",
            vec![
                "-s".to_owned(),
                "selected-device".to_owned(),
                "shell".to_owned(),
                "input".to_owned(),
                "keyevent".to_owned(),
                "KEYCODE_HOME".to_owned(),
            ],
        ),
        &CancellationToken::new(),
    );
    assert_eq!(
        result,
        Ok(omarchy_android_helper::process::CommandOutput { succeeded: false })
    );
    assert!(!format!("{result:?}").contains("private detail"));

    let unauthorized_adb = executable(
        directory.path(),
        "ordinary-unauthorized-adb",
        "printf 'error: device unauthorized' >&2\nexit 1",
    );
    let mut runner = AdbCommandRunner::new(unauthorized_adb, Duration::from_millis(2));
    assert_eq!(
        runner.run(
            CommandRequest::new("adb", vec!["devices".to_owned()]),
            &CancellationToken::new(),
        ),
        Ok(omarchy_android_helper::process::CommandOutput { succeeded: false })
    );
}

#[test]
fn adb_runner_deadline_kills_and_reaps_a_long_running_process() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let pid_file = directory.path().join("adb.pid");
    let fake_adb = executable(
        directory.path(),
        "adb",
        &format!(
            "printf '%s\\n' \"$$\" > '{}'\nexec sleep 5",
            pid_file.display()
        ),
    );
    let mut runner = AdbCommandRunner::new(fake_adb, Duration::from_millis(2));
    let session_cancellation = CancellationToken::new();
    let action_cancellation = session_cancellation.child_with_timeout(Duration::from_millis(500));
    let started = Instant::now();

    assert_eq!(
        runner.run(
            CommandRequest::new("adb", vec!["connect".to_owned(), "phone:1".to_owned()]),
            &action_cancellation,
        ),
        Err(CommandFailure::Cancelled)
    );
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "deadline cancellation did not bound the ADB command"
    );
    assert!(
        !session_cancellation.is_cancelled(),
        "the child deadline must not cancel its session parent"
    );

    let pid = fs::read_to_string(&pid_file)
        .expect("fake ADB recorded its pid")
        .trim()
        .to_owned();
    assert!(
        !Path::new("/proc").join(pid).exists(),
        "cancelled ADB child was not killed and waited"
    );
}

#[test]
fn adb_phone_target_deadline_ignores_descendant_output_pipe_lifetime() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let fake_adb = executable(
        directory.path(),
        "adb",
        "sleep 2 &\nwhile true; do sleep 1; done",
    );
    let mut runner = AdbCommandRunner::new(fake_adb, Duration::from_millis(2));
    let cancellation = CancellationToken::new().child_with_timeout(Duration::from_millis(100));
    let started = Instant::now();

    assert_eq!(
        runner.run_phone_target(
            CommandRequest::new(
                "adb",
                vec![
                    "-s".to_owned(),
                    "selected-device".to_owned(),
                    "shell".to_owned(),
                    "input".to_owned(),
                    "keyevent".to_owned(),
                    "KEYCODE_HOME".to_owned(),
                ],
            ),
            &cancellation,
        ),
        Err(ActionExecutionFailure::Cancelled)
    );
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "descendant-held output pipes defeated the action deadline"
    );
}

#[test]
fn avahi_matches_only_the_requested_service_then_associates_by_address() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let fake_avahi = executable(
        directory.path(),
        "avahi-browse",
        r#"
service="${@: -1}"
if [[ "$service" == "_adb-tls-pairing._tcp" ]]; then
  printf '%s\n' \
    '=;wlan0;IPv4;wrong-service;_adb-tls-pairing._tcp;local;phone.local;192.0.2.10;37000;' \
    '=;wlan0;IPv4;requested-service;_adb-tls-pairing._tcp;local;phone.local;192.0.2.20;37100;'
else
  printf '%s\n' \
    '=;wlan0;IPv4;unrelated-connect;_adb-tls-connect._tcp;local;other.local;192.0.2.30;38000;' \
    '=;wlan0;IPv4;adb-associated-connect;_adb-tls-connect._tcp;local;phone.local;192.0.2.20;38100;'
fi
exec sleep 5
"#,
    );
    let mut discovery =
        AvahiDiscovery::new(fake_avahi, Duration::from_secs(1), Duration::from_millis(2));
    let cancellation = CancellationToken::new();

    let pairing = discovery
        .find_pairing_endpoint("requested-service", &cancellation)
        .expect("requested pairing service");
    let connection = discovery
        .find_connection_endpoint(&pairing, &cancellation)
        .expect("associated connection service");

    assert!(pairing == PairingEndpoint::new("192.0.2.20", 37_100).expect("pairing endpoint"));
    assert!(connection == PairingEndpoint::new("192.0.2.20", 38_100).expect("connection endpoint"));
    let remembered = discovery
        .take_paired_device()
        .expect("associated trusted-device identity");
    assert_eq!(remembered.service_name(), "adb-associated-connect");
    let rediscovered = discovery
        .find_trusted_connection(&remembered, &cancellation)
        .expect("remembered connection service");
    assert!(rediscovered == PairingEndpoint::new("192.0.2.20", 38_100).expect("fresh endpoint"));
}

#[test]
fn avahi_timeout_cancellation_and_malformed_output_are_bounded() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let sleeping = executable(directory.path(), "sleeping-avahi", "exec sleep 5");
    let mut discovery = AvahiDiscovery::new(
        sleeping.clone(),
        Duration::from_millis(25),
        Duration::from_millis(2),
    );
    assert!(matches!(
        discovery.find_pairing_endpoint("requested", &CancellationToken::new()),
        Err(DiscoveryFailure::TimedOut)
    ));

    let mut discovery =
        AvahiDiscovery::new(sleeping, Duration::from_secs(2), Duration::from_millis(2));
    let cancellation = CancellationToken::new();
    let cancel_from_thread = cancellation.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(20));
        cancel_from_thread.cancel();
    });
    assert!(matches!(
        discovery.find_pairing_endpoint("requested", &cancellation),
        Err(DiscoveryFailure::Cancelled)
    ));

    let malformed = executable(
        directory.path(),
        "malformed-avahi",
        "printf '%s\\n' 'not avahi output' '=;too;short'",
    );
    let mut discovery =
        AvahiDiscovery::new(malformed, Duration::from_secs(1), Duration::from_millis(2));
    assert!(matches!(
        discovery.find_pairing_endpoint("requested", &CancellationToken::new()),
        Err(DiscoveryFailure::NetworkUnavailable)
    ));

    let out_of_range_escape = executable(
        directory.path(),
        "out-of-range-avahi",
        r#"printf '%s\n' '=;wlan0;IPv4;requested\999;_adb-tls-pairing._tcp;local;phone.local;192.0.2.40;39000;'"#,
    );
    let mut discovery = AvahiDiscovery::new(
        out_of_range_escape,
        Duration::from_secs(1),
        Duration::from_millis(2),
    );
    assert!(matches!(
        discovery.find_pairing_endpoint("requested", &CancellationToken::new()),
        Err(DiscoveryFailure::NetworkUnavailable)
    ));
}

#[test]
fn avahi_manual_discovery_accepts_one_service_and_rejects_ambiguity() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let one_service = executable(
        directory.path(),
        "one-service-avahi",
        "printf '%s\\n' '=;wlan0;IPv4;manual-phone;_adb-tls-pairing._tcp;local;phone.local;192.0.2.40;39000;'; exec sleep 5",
    );
    let mut discovery = AvahiDiscovery::new(
        one_service,
        Duration::from_secs(1),
        Duration::from_millis(5),
    );
    let endpoint = discovery
        .find_manual_pairing_endpoint(&CancellationToken::new())
        .expect("one manual pairing service");
    assert!(endpoint == PairingEndpoint::new("192.0.2.40", 39_000).expect("manual endpoint"));

    let ambiguous = executable(
        directory.path(),
        "ambiguous-avahi",
        "printf '%s\\n' '=;wlan0;IPv4;first;_adb-tls-pairing._tcp;local;first.local;192.0.2.41;39001;' '=;wlan0;IPv4;second;_adb-tls-pairing._tcp;local;second.local;192.0.2.42;39002;'; exec sleep 5",
    );
    let mut discovery =
        AvahiDiscovery::new(ambiguous, Duration::from_secs(1), Duration::from_millis(5));
    assert!(matches!(
        discovery.find_manual_pairing_endpoint(&CancellationToken::new()),
        Err(DiscoveryFailure::NetworkUnavailable)
    ));
}
