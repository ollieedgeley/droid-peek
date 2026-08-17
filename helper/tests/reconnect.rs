use std::{
    collections::VecDeque,
    convert::Infallible,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use omarchy_android_helper::{
    input::{AndroidKey, DisplayGeometry, NormalizedPoint},
    persistence::{FileTrustedDeviceStore, TrustedDevice},
    preferences::{FilePreferenceStore, Preferences, PreviewScale, QuickAction, VideoQuality},
    process::{CancellationToken, CommandFailure, CommandOutput, CommandRequest, CommandRunner},
    protocol::{Event, FailureReason, PairingBackend},
    runtime::{ProtocolSink, RuntimePairingBackend},
    session::{SessionExit, SessionFailure, SessionRunner},
    wireless::{DiscoveryFailure, PairingEndpoint, PairingFlow, WirelessDiscovery},
};

struct FakeDiscovery {
    trusted_result: Result<PairingEndpoint, DiscoveryFailure>,
    requested_devices: Vec<String>,
}

impl WirelessDiscovery for FakeDiscovery {
    fn find_pairing_endpoint(
        &mut self,
        _requested_service: &str,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        Err(DiscoveryFailure::NetworkUnavailable)
    }

    fn find_connection_endpoint(
        &mut self,
        _pairing_endpoint: &PairingEndpoint,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        Err(DiscoveryFailure::NetworkUnavailable)
    }

    fn find_trusted_connection(
        &mut self,
        device: &TrustedDevice,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        self.requested_devices
            .push(device.service_name().to_owned());
        self.trusted_result.clone()
    }
}

struct FakeRunner {
    outputs: VecDeque<Result<CommandOutput, CommandFailure>>,
    requests: Vec<CommandRequest>,
}

impl CommandRunner for FakeRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        _cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        self.requests.push(request);
        self.outputs.pop_front().expect("fake command output")
    }
}

#[derive(Clone)]
struct SharedRunner {
    outputs: Arc<Mutex<VecDeque<Result<CommandOutput, CommandFailure>>>>,
    requests: Arc<Mutex<Vec<CommandRequest>>>,
}

impl CommandRunner for SharedRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        _cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        self.requests.lock().expect("request lock").push(request);
        self.outputs
            .lock()
            .expect("output lock")
            .pop_front()
            .expect("fake command output")
    }
}

#[test]
fn reconnect_resolves_the_remembered_service_and_never_emits_its_endpoint() {
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device");
    let endpoint = PairingEndpoint::new("192.168.50.4", 37_123).expect("connection endpoint");
    let mut flow = PairingFlow::new(
        FakeDiscovery {
            trusted_result: Ok(endpoint),
            requested_devices: Vec::new(),
        },
        FakeRunner {
            outputs: VecDeque::from([Ok(CommandOutput { succeeded: true })]),
            requests: Vec::new(),
        },
    );

    let events = flow.reconnect(&device, &CancellationToken::new());

    assert_eq!(events, [Event::Connected.to_line()]);
    assert!(events.iter().all(|event| !event.contains("192.168.50.4")));
    assert!(
        events
            .iter()
            .all(|event| !event.contains(device.service_name()))
    );
    let (discovery, runner) = flow.into_parts();
    assert_eq!(discovery.requested_devices, [device.service_name()]);
    assert_eq!(runner.requests.len(), 1);
    assert_eq!(runner.requests[0].program(), "adb");
    assert_eq!(
        runner.requests[0].arguments(),
        ["connect", "192.168.50.4:37123"]
    );
}

#[test]
fn stale_remembered_service_reports_a_fixed_disconnected_failure() {
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device");
    let mut flow = PairingFlow::new(
        FakeDiscovery {
            trusted_result: Err(DiscoveryFailure::TimedOut),
            requested_devices: Vec::new(),
        },
        FakeRunner {
            outputs: VecDeque::new(),
            requests: Vec::new(),
        },
    );

    assert_eq!(
        flow.reconnect(&device, &CancellationToken::new()),
        [Event::Failure {
            reason: FailureReason::Disconnected,
        }
        .to_line()]
    );
    let (_, runner) = flow.into_parts();
    assert!(runner.requests.is_empty());
}

#[derive(Clone, Default)]
struct MemorySink {
    lines: Arc<Mutex<Vec<String>>>,
}

impl ProtocolSink for MemorySink {
    type Error = Infallible;

    fn emit_line(&self, line: &str) -> Result<(), Self::Error> {
        self.lines
            .lock()
            .expect("memory sink lock")
            .push(line.to_owned());
        Ok(())
    }
}

impl MemorySink {
    fn wait_for(&self, expected: &str) {
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if self
                .lines
                .lock()
                .expect("memory sink lock")
                .iter()
                .any(|line| line == expected)
            {
                return;
            }
            thread::sleep(Duration::from_millis(2));
        }
        panic!("event was not emitted");
    }

    fn wait_for_count(&self, expected: &str, count: usize) {
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if self
                .lines
                .lock()
                .expect("memory sink lock")
                .iter()
                .filter(|line| line.as_str() == expected)
                .count()
                >= count
            {
                return;
            }
            thread::sleep(Duration::from_millis(2));
        }
        panic!("event count was not reached");
    }
}

struct BlockingSession {
    target: Arc<Mutex<Option<String>>>,
    stopped: Arc<AtomicBool>,
    quality: VideoQuality,
    qualities: Arc<Mutex<Vec<VideoQuality>>>,
}

impl SessionRunner for BlockingSession {
    fn run(
        &mut self,
        target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(Option<omarchy_android_helper::session::PhysicalDisplaySize>),
    ) -> Result<SessionExit, SessionFailure> {
        self.qualities
            .lock()
            .expect("session qualities lock")
            .push(self.quality);
        *self.target.lock().expect("session target lock") = Some(target.to_owned());
        on_started(None);
        while !cancellation.is_cancelled() {
            thread::sleep(Duration::from_millis(2));
        }
        self.stopped.store(true, Ordering::Release);
        Ok(SessionExit::Stopped)
    }

    fn set_quality(&mut self, quality: VideoQuality) {
        self.quality = quality;
    }
}

#[test]
fn runtime_loads_private_state_and_reconnects_after_the_sync_response() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let state_directory = directory.path().join("state");
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&device)
        .expect("seed trusted-device state");
    let sink = MemorySink::default();
    let mut backend = RuntimePairingBackend::with_adapters_and_store(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        sink.clone(),
        FakeDiscovery {
            trusted_result: PairingEndpoint::new("192.168.50.4", 37_123)
                .map_err(|_| DiscoveryFailure::NetworkUnavailable),
            requested_devices: Vec::new(),
        },
        FakeRunner {
            outputs: VecDeque::from([Ok(CommandOutput { succeeded: true })]),
            requests: Vec::new(),
        },
    )
    .expect("runtime backend");

    assert!(backend.has_trusted_device());
    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    assert!(
        sink.lines.lock().expect("memory sink lock").is_empty(),
        "background work started before the protocol response"
    );
    backend.response_emitted();
    sink.wait_for(&Event::Connected.to_line());
}

#[test]
fn runtime_starts_scrcpy_after_reconnect_and_stops_it_before_confirmation() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let state_directory = directory.path().join("state");
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&device)
        .expect("seed trusted-device state");
    let sink = MemorySink::default();
    let target = Arc::new(Mutex::new(None));
    let stopped = Arc::new(AtomicBool::new(false));
    let qualities = Arc::new(Mutex::new(Vec::new()));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let outputs = Arc::new(Mutex::new(VecDeque::from([
        Ok(CommandOutput { succeeded: true }),
        Ok(CommandOutput { succeeded: true }),
        Ok(CommandOutput { succeeded: true }),
        Ok(CommandOutput { succeeded: true }),
    ])));
    let mut backend = RuntimePairingBackend::with_adapters_store_and_session(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        sink.clone(),
        FakeDiscovery {
            trusted_result: PairingEndpoint::new("192.168.50.4", 37_123)
                .map_err(|_| DiscoveryFailure::NetworkUnavailable),
            requested_devices: Vec::new(),
        },
        SharedRunner {
            outputs,
            requests: Arc::clone(&requests),
        },
        BlockingSession {
            target: Arc::clone(&target),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities,
        },
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    sink.wait_for(
        &Event::SessionStarted {
            physical_width_mm: None,
            physical_height_mm: None,
        }
        .to_line(),
    );
    assert_eq!(
        target.lock().expect("session target lock").as_deref(),
        Some("192.168.50.4:37123")
    );
    assert!(
        sink.lines
            .lock()
            .expect("memory sink lock")
            .iter()
            .all(|line| !line.contains("192.168.50.4"))
    );
    let geometry = DisplayGeometry::new(1080, 2400).expect("display geometry");
    backend
        .pointer_tap(
            geometry,
            NormalizedPoint::new(0.5, 0.25).expect("tap point"),
        )
        .expect("session tap");
    backend
        .key_input(AndroidKey::Back)
        .expect("session back key");
    backend.text_input("hello world").expect("session text");
    let requests_before_stop = requests.lock().expect("request lock");
    assert_eq!(requests_before_stop.len(), 4);
    assert_eq!(
        requests_before_stop[1].arguments(),
        [
            "-s",
            "192.168.50.4:37123",
            "shell",
            "input",
            "tap",
            "540",
            "600"
        ]
    );
    assert_eq!(
        requests_before_stop[2].arguments(),
        [
            "-s",
            "192.168.50.4:37123",
            "shell",
            "input",
            "keyevent",
            "KEYCODE_BACK"
        ]
    );
    assert_eq!(
        requests_before_stop[3].arguments(),
        [
            "-s",
            "192.168.50.4:37123",
            "shell",
            "input",
            "text",
            "'hello%sworld'"
        ]
    );
    drop(requests_before_stop);

    backend.stop_session();

    assert!(stopped.load(Ordering::Acquire));
}

#[test]
fn start_over_preserves_enabled_global_preference_across_a_different_device_reload() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let state_directory = directory.path().join("state");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device"))
        .expect("seed trusted-device state");
    let preferences = Preferences {
        keep_connected: true,
        android_mode_shortcuts: true,
        preview_scale: PreviewScale::new(125).expect("valid preview scale"),
        ..Preferences::default()
    };
    FilePreferenceStore::new(&state_directory)
        .save(&preferences)
        .expect("seed preferences");
    let sink = MemorySink::default();
    let stopped = Arc::new(AtomicBool::new(false));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let outputs = Arc::new(Mutex::new(VecDeque::from([
        Ok(CommandOutput { succeeded: true }),
        Err(CommandFailure::DependencyUnavailable),
    ])));
    let mut backend = RuntimePairingBackend::with_adapters_store_and_session(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        sink.clone(),
        FakeDiscovery {
            trusted_result: PairingEndpoint::new("192.168.50.4", 37_123)
                .map_err(|_| DiscoveryFailure::NetworkUnavailable),
            requested_devices: Vec::new(),
        },
        SharedRunner {
            outputs,
            requests: Arc::clone(&requests),
        },
        BlockingSession {
            target: Arc::new(Mutex::new(None)),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities: Arc::new(Mutex::new(Vec::new())),
        },
    )
    .expect("runtime backend");
    assert_eq!(backend.preferences(), preferences);

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    sink.wait_for(
        &Event::SessionStarted {
            physical_width_mm: None,
            physical_height_mm: None,
        }
        .to_line(),
    );

    backend.start_over().expect("start over");

    assert!(stopped.load(Ordering::Acquire));
    assert!(!backend.has_trusted_device());
    assert!(
        FileTrustedDeviceStore::new(&state_directory)
            .load()
            .expect("load trusted state")
            .is_none()
    );
    assert_eq!(
        FilePreferenceStore::new(&state_directory)
            .load()
            .expect("load preserved preferences"),
        preferences
    );
    let requests = requests.lock().expect("request lock");
    assert_eq!(requests.len(), 2);
    assert_eq!(
        requests[1].arguments(),
        ["disconnect", "192.168.50.4:37123"]
    );
    drop(requests);
    drop(backend);

    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-SECONDDEVICE123").expect("replacement trusted device"))
        .expect("seed replacement trusted-device state");
    let reloaded_backend = RuntimePairingBackend::with_adapters_and_store(
        directory.path().join("reloaded-runtime"),
        &state_directory,
        Duration::from_secs(1),
        MemorySink::default(),
        FakeDiscovery {
            trusted_result: Err(DiscoveryFailure::NetworkUnavailable),
            requested_devices: Vec::new(),
        },
        FakeRunner {
            outputs: VecDeque::new(),
            requests: Vec::new(),
        },
    )
    .expect("reloaded runtime backend");

    assert!(reloaded_backend.has_trusted_device());
    assert_eq!(reloaded_backend.preferences(), preferences);
}

#[test]
fn quality_update_is_persisted_and_restarts_only_the_active_session() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let state_directory = directory.path().join("state");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device"))
        .expect("seed trusted-device state");
    let sink = MemorySink::default();
    let target = Arc::new(Mutex::new(None));
    let stopped = Arc::new(AtomicBool::new(false));
    let qualities = Arc::new(Mutex::new(Vec::new()));
    let mut backend = RuntimePairingBackend::with_adapters_store_and_session(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        sink.clone(),
        FakeDiscovery {
            trusted_result: PairingEndpoint::new("192.168.50.4", 37_123)
                .map_err(|_| DiscoveryFailure::NetworkUnavailable),
            requested_devices: Vec::new(),
        },
        FakeRunner {
            outputs: VecDeque::from([Ok(CommandOutput { succeeded: true })]),
            requests: Vec::new(),
        },
        BlockingSession {
            target,
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::Low,
            qualities: Arc::clone(&qualities),
        },
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    sink.wait_for_count(
        &Event::SessionStarted {
            physical_width_mm: None,
            physical_height_mm: None,
        }
        .to_line(),
        1,
    );

    let retained_preferences = Preferences {
        keep_connected: true,
        ..Preferences::default()
    };
    assert!(
        !backend
            .set_preferences(retained_preferences)
            .expect("save keep-connected preference")
    );
    assert_eq!(
        qualities.lock().expect("session qualities lock").as_slice(),
        [VideoQuality::High]
    );

    let preferences = Preferences {
        keep_connected: true,
        android_mode_shortcuts: false,
        command_passthrough: false,
        preview_scale: PreviewScale::new(150).expect("valid preview scale"),
        video_quality: VideoQuality::Low,
        quick_actions: [
            QuickAction::Home,
            QuickAction::RecentApps,
            QuickAction::Back,
        ],
    };
    assert!(
        backend
            .set_preferences(preferences)
            .expect("save and restart session")
    );
    sink.wait_for_count(
        &Event::SessionStarted {
            physical_width_mm: None,
            physical_height_mm: None,
        }
        .to_line(),
        2,
    );
    assert_eq!(
        qualities.lock().expect("session qualities lock").as_slice(),
        [VideoQuality::High, VideoQuality::Low]
    );
    assert!(stopped.load(Ordering::Acquire));
    assert_eq!(
        FilePreferenceStore::new(&state_directory)
            .load()
            .expect("load saved preferences"),
        preferences
    );

    backend.stop_session();
}
