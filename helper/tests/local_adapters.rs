#![cfg(unix)]

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::Mutex,
    thread,
    time::Duration,
};

use omarchy_android_helper::{
    process::{AdbCommandRunner, CancellationToken, CommandFailure, CommandRequest, CommandRunner},
    wireless::{AvahiDiscovery, DiscoveryFailure, PairingEndpoint, WirelessDiscovery},
};

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
fn adb_runner_uses_separated_arguments_and_discards_output() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let arguments_file = directory.path().join("arguments");
    let fake_adb = executable(
        directory.path(),
        "adb",
        &format!(
            "printf '%s\\n' \"$@\" > '{}'\nprintf 'raw endpoint and secret'\nprintf 'raw failure' >&2",
            arguments_file.display()
        ),
    );
    let mut runner = AdbCommandRunner::new(fake_adb, Duration::from_millis(2));

    let output = runner
        .run(
            CommandRequest::new(
                "adb",
                vec![
                    "pair".to_owned(),
                    "phone.local:37000".to_owned(),
                    "temporary-secret".to_owned(),
                ],
            ),
            &CancellationToken::new(),
        )
        .expect("fake ADB command");

    assert!(output.succeeded);
    assert_eq!(
        fs::read_to_string(arguments_file).expect("recorded arguments"),
        "pair\nphone.local:37000\ntemporary-secret\n"
    );
}

#[test]
fn adb_runner_stops_a_cancelled_process() {
    let _process_guard = PROCESS_TEST_LOCK.lock().expect("process test lock");
    let directory = tempfile::tempdir().expect("temporary directory");
    let fake_adb = executable(directory.path(), "adb", "exec sleep 5");
    let mut runner = AdbCommandRunner::new(fake_adb, Duration::from_millis(2));
    let cancellation = CancellationToken::new();
    let cancel_from_thread = cancellation.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(20));
        cancel_from_thread.cancel();
    });

    assert_eq!(
        runner.run(
            CommandRequest::new("adb", vec!["connect".to_owned(), "phone:1".to_owned()]),
            &cancellation,
        ),
        Err(CommandFailure::Cancelled)
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
