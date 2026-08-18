use std::{
    collections::VecDeque,
    convert::Infallible,
    os::unix::fs::symlink,
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
    protocol::{Event, PairingBackend},
    runtime::{ProtocolSink, RuntimePairingBackend},
    session::{SessionExit, SessionFailure, SessionRunner},
    wireless::{DiscoveryFailure, PairingEndpoint, PairingFlow, WirelessDiscovery},
};

const HELPER_EPOCH: &str = "73001";

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

fn collect_events(run: impl FnOnce(&mut dyn FnMut(Event))) -> Vec<Event> {
    let mut events = Vec::new();
    run(&mut |event| events.push(event));
    events
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

    let events = collect_events(|emit| {
        flow.reconnect_with(&device, &CancellationToken::new(), emit);
    });

    assert_eq!(events.len(), 1);
    assert_eq!(
        flow.take_connected_target().as_deref(),
        Some("192.168.50.4:37123")
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

    let events = collect_events(|emit| {
        flow.reconnect_with(&device, &CancellationToken::new(), emit);
    });
    assert_eq!(events.len(), 1);
    let (_, runner) = flow.into_parts();
    assert!(runner.requests.is_empty());
}

#[derive(Clone, Default)]
struct MemorySink {
    lines: Arc<Mutex<Vec<String>>>,
}

impl ProtocolSink for MemorySink {
    type Error = Infallible;

    fn emit_event(&self, event: &Event) -> Result<(), Self::Error> {
        self.lines
            .lock()
            .expect("memory sink lock")
            .push(event.to_line());
        Ok(())
    }
}

impl MemorySink {
    fn wait_for_event(&self, event_type: &str, generation: Option<&str>) -> String {
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if let Some(line) = self
                .lines
                .lock()
                .expect("memory sink lock")
                .iter()
                .find(|line| {
                    let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
                        return false;
                    };
                    value["type"] == event_type
                        && value["helperEpoch"] == HELPER_EPOCH
                        && generation.is_none_or(|expected| {
                            value["sessionGeneration"].as_str() == Some(expected)
                        })
                })
                .cloned()
            {
                return line;
            }
            thread::sleep(Duration::from_millis(2));
        }
        panic!("event {event_type} at generation {generation:?} was not emitted");
    }

    fn event_count(&self, event_type: &str, generation: &str) -> usize {
        self.lines
            .lock()
            .expect("memory sink lock")
            .iter()
            .filter(|line| {
                serde_json::from_str::<serde_json::Value>(line).is_ok_and(|value| {
                    value["type"] == event_type
                        && value["helperEpoch"] == HELPER_EPOCH
                        && value["sessionGeneration"] == generation
                })
            })
            .count()
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
    let mut backend = RuntimePairingBackend::with_dependencies(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
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
        None,
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
    sink.wait_for_event("connected", Some("1"));
}

#[test]
fn reconnect_transport_failure_advances_generation_before_lifecycle_event() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let state_directory = directory.path().join("state");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device"))
        .expect("seed trusted-device state");
    let sink = MemorySink::default();
    let mut backend = RuntimePairingBackend::with_dependencies(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
        sink.clone(),
        FakeDiscovery {
            trusted_result: Err(DiscoveryFailure::NetworkUnavailable),
            requested_devices: Vec::new(),
        },
        FakeRunner {
            outputs: VecDeque::new(),
            requests: Vec::new(),
        },
        None,
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();

    let failure = sink.wait_for_event("lifecycle-failure", Some("2"));
    let failure: serde_json::Value =
        serde_json::from_str(&failure).expect("lifecycle failure event");
    assert_eq!(failure["reason"], "network-unavailable");
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
    let mut backend = RuntimePairingBackend::with_dependencies(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
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
        Some(Box::new(BlockingSession {
            target: Arc::clone(&target),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities,
        })),
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    sink.wait_for_event("session-started", Some("1"));
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
    sink.wait_for_event("session-ended", Some("2"));

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
    let mut backend = RuntimePairingBackend::with_dependencies(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
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
        Some(Box::new(BlockingSession {
            target: Arc::new(Mutex::new(None)),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities: Arc::new(Mutex::new(Vec::new())),
        })),
    )
    .expect("runtime backend");
    assert_eq!(backend.preferences(), preferences);

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    sink.wait_for_event("session-started", Some("1"));

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
    let reloaded_backend = RuntimePairingBackend::with_dependencies(
        directory.path().join("reloaded-runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
        MemorySink::default(),
        FakeDiscovery {
            trusted_result: Err(DiscoveryFailure::NetworkUnavailable),
            requested_devices: Vec::new(),
        },
        FakeRunner {
            outputs: VecDeque::new(),
            requests: Vec::new(),
        },
        None,
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
    let mut backend = RuntimePairingBackend::with_dependencies(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
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
        Some(Box::new(BlockingSession {
            target,
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::Low,
            qualities: Arc::clone(&qualities),
        })),
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    sink.wait_for_event("session-started", Some("1"));

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
    sink.wait_for_event("session-started", Some("2"));
    assert_eq!(sink.event_count("session-started", "1"), 1);
    assert_eq!(sink.event_count("session-started", "2"), 1);
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

#[test]
fn runtime_rejects_a_symlinked_private_state_root_before_loading() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let target = directory.path().join("target-state");
    std::fs::create_dir(&target).expect("state target");
    let state_directory = directory.path().join("state");
    symlink(&target, &state_directory).expect("state symlink");

    let result = RuntimePairingBackend::with_dependencies(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
        MemorySink::default(),
        FakeDiscovery {
            trusted_result: Err(DiscoveryFailure::NetworkUnavailable),
            requested_devices: Vec::new(),
        },
        FakeRunner {
            outputs: VecDeque::new(),
            requests: Vec::new(),
        },
        None,
    );
    let error = match result {
        Ok(_) => panic!("symlinked state root was accepted"),
        Err(error) => error,
    };
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
}
