use std::{
    collections::VecDeque,
    convert::Infallible,
    fs,
    os::unix::fs::symlink,
    path::PathBuf,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc::{self, Receiver, RecvTimeoutError, Sender},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use droid_peek_helper::{
    actions::PhoneTarget,
    input::{AndroidKey, DisplayGeometry, NormalizedPoint},
    persistence::{FileTrustedDeviceStore, TrustedDevice},
    preferences::{FilePreferenceStore, Preferences, PreviewScale, QuickAction, VideoQuality},
    process::{
        ActionExecutionFailure, CancellationToken, CommandFailure, CommandOutput, CommandRequest,
        CommandRunner,
    },
    protocol::{
        ActionFailureCode, Event, FailureReason, PairingBackend, PairingEvent, PhoneTargetFailure,
        ProtocolEngine,
    },
    runtime::{ProtocolSink, RuntimeDependencies, RuntimePairingBackend},
    scrcpy_config::{FileScrcpyConfigStore, ScrcpyConfiguration},
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
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        if cancellation.is_cancelled() {
            return Err(DiscoveryFailure::Cancelled);
        }
        self.requested_devices
            .push(device.service_name().to_owned());
        self.trusted_result.clone()
    }
}

struct BlockingReconnectDiscovery {
    started: Arc<AtomicBool>,
}

impl WirelessDiscovery for BlockingReconnectDiscovery {
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
        _device: &TrustedDevice,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        self.started.store(true, Ordering::Release);
        loop {
            if cancellation.is_cancelled() {
                return Err(DiscoveryFailure::Cancelled);
            }
            thread::sleep(Duration::from_millis(2));
        }
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
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        if cancellation.is_cancelled() {
            return Err(CommandFailure::Cancelled);
        }
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
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        if cancellation.is_cancelled() {
            return Err(CommandFailure::Cancelled);
        }
        self.requests.lock().expect("request lock").push(request);
        self.outputs
            .lock()
            .expect("output lock")
            .pop_front()
            .expect("fake command output")
    }
}

#[derive(Clone)]
struct PhoneTargetRunner {
    result: Result<CommandOutput, ActionExecutionFailure>,
    requests: Arc<Mutex<Vec<CommandRequest>>>,
}

impl CommandRunner for PhoneTargetRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        if cancellation.is_cancelled() {
            return Err(CommandFailure::Cancelled);
        }
        self.requests.lock().expect("request lock").push(request);
        Ok(CommandOutput { succeeded: true })
    }

    fn run_phone_target(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, ActionExecutionFailure> {
        if cancellation.is_cancelled() {
            return Err(ActionExecutionFailure::Cancelled);
        }
        self.requests.lock().expect("request lock").push(request);
        self.result
    }
}

fn collect_events(run: impl FnOnce(&mut dyn FnMut(PairingEvent))) -> Vec<PairingEvent> {
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

#[test]
fn cancelled_command_runner_does_not_report_queued_success() {
    let mut runner = FakeRunner {
        outputs: VecDeque::from([Ok(CommandOutput { succeeded: true })]),
        requests: Vec::new(),
    };
    let cancellation = CancellationToken::new();
    cancellation.cancel();

    assert_eq!(
        runner.run(
            CommandRequest::new("adb", vec!["connect".to_owned()]),
            &cancellation,
        ),
        Err(CommandFailure::Cancelled)
    );
    assert!(runner.requests.is_empty());
}

#[test]
fn cancelled_shared_runner_does_not_report_queued_success() {
    let mut runner = SharedRunner {
        outputs: Arc::new(Mutex::new(VecDeque::from([Ok(CommandOutput {
            succeeded: true,
        })]))),
        requests: Arc::new(Mutex::new(Vec::new())),
    };
    let cancellation = CancellationToken::new();
    cancellation.cancel();

    assert_eq!(
        runner.run(
            CommandRequest::new("adb", vec!["connect".to_owned()]),
            &cancellation,
        ),
        Err(CommandFailure::Cancelled)
    );
    assert!(runner.requests.lock().expect("request lock").is_empty());
}

#[test]
fn cancelled_phone_target_runner_does_not_report_success() {
    let mut runner = PhoneTargetRunner {
        result: Ok(CommandOutput { succeeded: true }),
        requests: Arc::new(Mutex::new(Vec::new())),
    };
    let cancellation = CancellationToken::new();
    cancellation.cancel();

    assert_eq!(
        runner.run(
            CommandRequest::new("adb", vec!["connect".to_owned()]),
            &cancellation,
        ),
        Err(CommandFailure::Cancelled)
    );
    assert_eq!(
        runner.run_phone_target(
            CommandRequest::new("adb", vec!["shell".to_owned()]),
            &cancellation,
        ),
        Err(ActionExecutionFailure::Cancelled)
    );
    assert!(runner.requests.lock().expect("request lock").is_empty());
}

#[test]
fn cancelled_blocking_reconnect_discovery_returns_without_release() {
    let mut discovery = BlockingReconnectDiscovery {
        started: Arc::new(AtomicBool::new(false)),
    };
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device");

    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = discovery.find_trusted_connection(&device, &cancellation);
        let _ = tx.send(result);
    });
    let result = rx
        .recv_timeout(Duration::from_millis(200))
        .expect("cancelled discovery should not block");
    assert!(matches!(result, Err(DiscoveryFailure::Cancelled)));
}

#[test]
fn cancelled_trusted_connection_does_not_return_a_queued_endpoint() {
    let endpoint = PairingEndpoint::new("192.168.50.4", 37_123).expect("connection endpoint");
    let mut discovery = FakeDiscovery {
        trusted_result: Ok(endpoint),
        requested_devices: Vec::new(),
    };
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let device = TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device");

    assert!(matches!(
        discovery.find_trusted_connection(&device, &cancellation),
        Err(DiscoveryFailure::Cancelled)
    ));
    assert!(discovery.requested_devices.is_empty());
}

#[derive(Clone, Default)]
struct MemorySink {
    lines: Arc<Mutex<Vec<String>>>,
    changed: Arc<Condvar>,
}

impl ProtocolSink for MemorySink {
    type Error = Infallible;

    fn emit_event(&self, event: &Event) -> Result<(), Self::Error> {
        self.lines
            .lock()
            .expect("memory sink lock")
            .push(event.to_line());
        self.changed.notify_all();
        Ok(())
    }
}

impl MemorySink {
    fn wait_for_event(&self, event_type: &str, generation: Option<&str>) -> String {
        let deadline = Instant::now() + Duration::from_secs(1);
        let mut lines = self.lines.lock().expect("memory sink lock");
        loop {
            if let Some(line) = lines
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
            let now = Instant::now();
            assert!(
                now < deadline,
                "event {event_type} at generation {generation:?} was not emitted"
            );
            let (next_lines, _) = self
                .changed
                .wait_timeout(lines, deadline.saturating_duration_since(now))
                .expect("memory sink condition");
            lines = next_lines;
        }
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

    fn session_event_identities(&self) -> Vec<(String, String)> {
        self.lines
            .lock()
            .expect("memory sink lock")
            .iter()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter_map(|value| {
                let event_type = value["type"].as_str()?;
                (event_type.starts_with("session-") || event_type == "lifecycle-failure").then(
                    || {
                        (
                            event_type.to_owned(),
                            value["sessionGeneration"]
                                .as_str()
                                .expect("session event generation")
                                .to_owned(),
                        )
                    },
                )
            })
            .collect()
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
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        self.qualities
            .lock()
            .expect("session qualities lock")
            .push(self.quality);
        *self.target.lock().expect("session target lock") = Some(target.to_owned());
        on_started();
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

struct RecordingConfigSession {
    current_arguments: Vec<String>,
    runs: Arc<Mutex<Vec<Vec<String>>>>,
}

impl SessionRunner for RecordingConfigSession {
    fn run(
        &mut self,
        _target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        self.runs
            .lock()
            .expect("session argument runs lock")
            .push(self.current_arguments.clone());
        on_started();
        while !cancellation.is_cancelled() {
            thread::sleep(Duration::from_millis(2));
        }
        Ok(SessionExit::Stopped)
    }

    fn set_scrcpy_arguments(&mut self, arguments: Vec<String>) {
        self.current_arguments = arguments;
    }
}

struct BlockingQualitySession {
    quality_update_started: Arc<AtomicBool>,
    release_quality_update: Arc<AtomicBool>,
    run_called: Arc<AtomicBool>,
}

impl SessionRunner for BlockingQualitySession {
    fn run(
        &mut self,
        _target: &str,
        _cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        self.run_called.store(true, Ordering::Release);
        on_started();
        Ok(SessionExit::Ended)
    }

    fn set_quality(&mut self, _quality: VideoQuality) {
        self.quality_update_started.store(true, Ordering::Release);
        while !self.release_quality_update.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(2));
        }
    }
}

struct EndingSession {
    cancellation: Arc<Mutex<Option<CancellationToken>>>,
    release: Receiver<()>,
}

impl SessionRunner for EndingSession {
    fn run(
        &mut self,
        _target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        *self.cancellation.lock().expect("session cancellation lock") = Some(cancellation.clone());
        on_started();
        self.release
            .recv_timeout(Duration::from_secs(1))
            .expect("release ending session");
        Ok(SessionExit::Ended)
    }
}

struct ControlledSession {
    outcomes: VecDeque<Result<SessionExit, SessionFailure>>,
    releases: Receiver<()>,
    runs: Arc<AtomicUsize>,
}

impl SessionRunner for ControlledSession {
    fn run(
        &mut self,
        _target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(),
    ) -> Result<SessionExit, SessionFailure> {
        self.runs.fetch_add(1, Ordering::AcqRel);
        on_started();
        loop {
            match self.releases.recv_timeout(Duration::from_millis(10)) {
                Ok(()) => {
                    return self
                        .outcomes
                        .pop_front()
                        .expect("controlled session outcome");
                }
                Err(RecvTimeoutError::Timeout) if cancellation.is_cancelled() => {
                    return Ok(SessionExit::Stopped);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return Ok(SessionExit::Stopped),
            }
        }
    }
}

fn controlled_session(
    outcomes: impl IntoIterator<Item = Result<SessionExit, SessionFailure>>,
) -> (Box<dyn SessionRunner + Send>, Sender<()>, Arc<AtomicUsize>) {
    let (release, releases) = mpsc::channel();
    let runs = Arc::new(AtomicUsize::new(0));
    (
        Box::new(ControlledSession {
            outcomes: outcomes.into_iter().collect(),
            releases,
            runs: Arc::clone(&runs),
        }),
        release,
        runs,
    )
}

#[derive(Clone)]
struct BlockingRetrySink {
    events: MemorySink,
    blocked: Arc<AtomicBool>,
    entered: Sender<()>,
    release: Arc<Mutex<Receiver<()>>>,
}

impl ProtocolSink for BlockingRetrySink {
    type Error = Infallible;

    fn emit_event(&self, event: &Event) -> Result<(), Self::Error> {
        let blocks_retry = matches!(
            event,
            Event::SessionStarting {
                session_generation,
                ..
            } if session_generation == "2"
        ) && !self.blocked.swap(true, Ordering::AcqRel);
        if blocks_retry {
            self.entered.send(()).expect("announce blocked retry");
            self.release
                .lock()
                .expect("retry release lock")
                .recv_timeout(Duration::from_secs(1))
                .expect("release blocked retry");
        }
        self.events.emit_event(event)
    }
}

struct RetrySinkGate {
    entered: Receiver<()>,
    release: Sender<()>,
}

impl RetrySinkGate {
    fn wait_until_blocked(&self) {
        self.entered
            .recv_timeout(Duration::from_secs(1))
            .expect("retry announcement entered sink");
    }

    fn release(&self) {
        self.release.send(()).expect("release retry announcement");
    }
}

fn blocking_retry_sink() -> (BlockingRetrySink, RetrySinkGate) {
    let (entered, wait_for_entry) = mpsc::channel();
    let (release, wait_for_release) = mpsc::channel();
    (
        BlockingRetrySink {
            events: MemorySink::default(),
            blocked: Arc::new(AtomicBool::new(false)),
            entered,
            release: Arc::new(Mutex::new(wait_for_release)),
        },
        RetrySinkGate {
            entered: wait_for_entry,
            release,
        },
    )
}

struct LiveRuntime<S: ProtocolSink = MemorySink> {
    _directory: tempfile::TempDir,
    state_directory: PathBuf,
    runtime_directory: PathBuf,
    backend: RuntimePairingBackend<S>,
    sink: S,
    requests: Arc<Mutex<Vec<CommandRequest>>>,
}

fn live_runtime(
    session: Box<dyn SessionRunner + Send>,
    outputs: VecDeque<Result<CommandOutput, CommandFailure>>,
) -> LiveRuntime {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let runner = SharedRunner {
        outputs: Arc::new(Mutex::new(outputs)),
        requests: Arc::clone(&requests),
    };
    live_runtime_with_runner(session, runner, requests)
}

fn live_runtime_with_runner(
    session: Box<dyn SessionRunner + Send>,
    runner: impl CommandRunner + Send + 'static,
    requests: Arc<Mutex<Vec<CommandRequest>>>,
) -> LiveRuntime {
    let sink = MemorySink::default();
    let live = live_runtime_with_sink_and_runner(session, runner, requests, sink, None);
    live.sink.wait_for_event("session-started", Some("1"));
    live
}

fn live_runtime_with_retry_sink(
    session: Box<dyn SessionRunner + Send>,
    sink: BlockingRetrySink,
) -> LiveRuntime<BlockingRetrySink> {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let runner = SharedRunner {
        outputs: Arc::new(Mutex::new(VecDeque::from([Ok(CommandOutput {
            succeeded: true,
        })]))),
        requests: Arc::clone(&requests),
    };
    let live = live_runtime_with_sink_and_runner(session, runner, requests, sink, None);
    live.sink
        .events
        .wait_for_event("session-started", Some("1"));
    live
}

fn live_runtime_with_scrcpy_configuration(
    session: Box<dyn SessionRunner + Send>,
    configuration: &ScrcpyConfiguration,
) -> LiveRuntime {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let runner = SharedRunner {
        outputs: Arc::new(Mutex::new(VecDeque::from([Ok(CommandOutput {
            succeeded: true,
        })]))),
        requests: Arc::clone(&requests),
    };
    let sink = MemorySink::default();
    let live =
        live_runtime_with_sink_and_runner(session, runner, requests, sink, Some(configuration));
    live.sink.wait_for_event("session-started", Some("1"));
    live
}

fn live_runtime_with_sink_and_runner<S: ProtocolSink>(
    session: Box<dyn SessionRunner + Send>,
    runner: impl CommandRunner + Send + 'static,
    requests: Arc<Mutex<Vec<CommandRequest>>>,
    sink: S,
    scrcpy_configuration: Option<&ScrcpyConfiguration>,
) -> LiveRuntime<S> {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let state_directory = directory.path().join("state");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device"))
        .expect("seed trusted-device state");
    if let Some(configuration) = scrcpy_configuration {
        FileScrcpyConfigStore::new(&state_directory)
            .store(configuration)
            .expect("seed scrcpy configuration");
    }
    let runtime_directory = directory.path().join("runtime");
    let mut backend = RuntimePairingBackend::with_dependencies(
        &runtime_directory,
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
        sink.clone(),
        RuntimeDependencies::new(
            FakeDiscovery {
                trusted_result: PairingEndpoint::new("192.168.50.4", 37_123)
                    .map_err(|_| DiscoveryFailure::NetworkUnavailable),
                requested_devices: Vec::new(),
            },
            runner,
            Some(session),
        ),
    )
    .expect("runtime backend");
    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    LiveRuntime {
        _directory: directory,
        state_directory,
        runtime_directory,
        backend,
        sink,
        requests,
    }
}

#[test]
fn scrcpy_configuration_restarts_with_only_the_effective_screen_off_state() {
    let runs = Arc::new(Mutex::new(Vec::new()));
    let configuration = ScrcpyConfiguration::validated(vec![
        "--keep-active".to_owned(),
        "--turn-screen-off".to_owned(),
    ])
    .expect("valid scrcpy configuration");
    let mut live = live_runtime_with_scrcpy_configuration(
        Box::new(RecordingConfigSession {
            current_arguments: Vec::new(),
            runs: Arc::clone(&runs),
        }),
        &configuration,
    );
    let started = live.sink.wait_for_event("session-started", Some("1"));
    assert_eq!(
        runs.lock().expect("session argument runs lock").as_slice(),
        [vec![
            "--keep-active".to_owned(),
            "--turn-screen-off".to_owned()
        ]]
    );
    assert!(
        started.contains(r#""screenOffEnabled":true"#),
        "first session should apply stored screen-off: {started}"
    );

    live.backend.response_emitted();
    let mut preferences = live.backend.preferences();
    preferences.video_quality = VideoQuality::Low;
    assert!(
        live.backend
            .set_preferences(preferences)
            .expect("change quality after first screen-off session")
    );
    let retained_event = live.sink.wait_for_event("session-started", Some("2"));
    assert_eq!(
        runs.lock().expect("session argument runs lock")[1],
        ["--keep-active".to_owned(), "--turn-screen-off".to_owned()]
    );
    assert!(
        retained_event.contains(r#""screenOffEnabled":true"#),
        "quality restart should retain screen-off: {retained_event}"
    );

    let uncommitted =
        ScrcpyConfiguration::validated(vec!["--stay-awake".to_owned()]).expect("valid candidate");
    assert!(
        live.backend
            .set_scrcpy_configuration(uncommitted, false)
            .is_err()
    );
    assert_eq!(runs.lock().expect("session argument runs lock").len(), 2);
    live.backend.stop_session();
}

#[test]
fn first_reconnect_with_stored_screen_off_does_not_restart_only_to_enable_the_flag() {
    let runs = Arc::new(Mutex::new(Vec::new()));
    let configuration = ScrcpyConfiguration::validated(vec![
        "--keep-active".to_owned(),
        "--turn-screen-off".to_owned(),
    ])
    .expect("valid scrcpy configuration");
    let mut live = live_runtime_with_scrcpy_configuration(
        Box::new(RecordingConfigSession {
            current_arguments: Vec::new(),
            runs: Arc::clone(&runs),
        }),
        &configuration,
    );
    let started = live.sink.wait_for_event("session-started", Some("1"));

    assert!(
        started.contains(r#""screenOffEnabled":true"#),
        "first session should apply stored screen-off: {started}"
    );
    assert_eq!(
        runs.lock().expect("session argument runs lock").as_slice(),
        [vec![
            "--keep-active".to_owned(),
            "--turn-screen-off".to_owned()
        ]]
    );
    assert_eq!(live.sink.event_count("session-started", "2"), 0);
    live.backend.stop_session();
}

#[test]
fn every_input_backend_failure_reaps_the_session_before_emitting_the_new_generation() {
    for command in [
        r#"{"version":11,"type":"pointer-tap","helperEpoch":"73001","sessionGeneration":"1","x":0.5,"y":0.5,"displayWidth":1080,"displayHeight":2400}"#,
        r#"{"version":11,"type":"pointer-swipe","helperEpoch":"73001","sessionGeneration":"1","startX":0.1,"startY":0.2,"endX":0.8,"endY":0.9,"displayWidth":1080,"displayHeight":2400,"durationMs":320}"#,
        r#"{"version":11,"type":"key-input","helperEpoch":"73001","sessionGeneration":"1","key":"home"}"#,
        r#"{"version":11,"type":"text-input","helperEpoch":"73001","sessionGeneration":"1","text":"hello"}"#,
    ] {
        let stopped = Arc::new(AtomicBool::new(false));
        let live = live_runtime(
            Box::new(BlockingSession {
                target: Arc::new(Mutex::new(None)),
                stopped: Arc::clone(&stopped),
                quality: VideoQuality::default(),
                qualities: Arc::new(Mutex::new(Vec::new())),
            }),
            VecDeque::from([
                Ok(CommandOutput { succeeded: true }),
                Err(CommandFailure::Unauthorized),
            ]),
        );
        let mut engine = ProtocolEngine::new(live.backend, HELPER_EPOCH);

        let events = engine.handle_line(command);

        assert_eq!(
            events
                .into_iter()
                .map(|event| event.to_line())
                .collect::<Vec<_>>(),
            [
                r#"{"version":11,"type":"lifecycle-failure","helperEpoch":"73001","sessionGeneration":"2","reason":"disconnected"}"#
            ]
        );
        let backend = engine.into_backend();
        assert_eq!(backend.session_generation(), 2);
        assert!(stopped.load(Ordering::Acquire));
    }
}

#[test]
fn stop_session_command_emits_only_session_stopped() {
    let stopped = Arc::new(AtomicBool::new(false));
    let live = live_runtime(
        Box::new(BlockingSession {
            target: Arc::new(Mutex::new(None)),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities: Arc::new(Mutex::new(Vec::new())),
        }),
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );
    let mut engine = ProtocolEngine::new(live.backend, HELPER_EPOCH);

    let events = engine.handle_line(
        r#"{"version":11,"type":"stop-session","helperEpoch":"73001","sessionGeneration":"1"}"#,
    );

    assert_eq!(
        events
            .into_iter()
            .map(|event| event.to_line())
            .collect::<Vec<_>>(),
        [
            r#"{"version":11,"type":"session-stopped","helperEpoch":"73001","sessionGeneration":"2"}"#
        ]
    );
    let backend = engine.into_backend();
    assert_eq!(backend.session_generation(), 2);
    assert!(stopped.load(Ordering::Acquire));
    assert_eq!(live.sink.event_count("session-ended", "2"), 0);
    assert!(
        live.sink
            .session_event_identities()
            .into_iter()
            .all(|(event_type, _)| event_type != "session-ended"),
        "user stop must not emit session-ended: {:?}",
        live.sink.session_event_identities()
    );
}

#[test]
fn phone_target_transport_failures_invalidate_and_wait_for_the_active_session() {
    for (failure, reason) in [
        (
            ActionExecutionFailure::Disconnected,
            FailureReason::Disconnected,
        ),
        (
            ActionExecutionFailure::Unauthorized,
            FailureReason::Unauthorized,
        ),
    ] {
        let stopped = Arc::new(AtomicBool::new(false));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let mut live = live_runtime_with_runner(
            Box::new(BlockingSession {
                target: Arc::new(Mutex::new(None)),
                stopped: Arc::clone(&stopped),
                quality: VideoQuality::default(),
                qualities: Arc::new(Mutex::new(Vec::new())),
            }),
            PhoneTargetRunner {
                result: Err(failure),
                requests: Arc::clone(&requests),
            },
            requests,
        );
        let expires_at_unix_ms = u64::try_from(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system clock after epoch")
                .as_millis(),
        )
        .expect("current time fits u64")
            + 1_000;

        assert_eq!(
            live.backend.phone_target(
                PhoneTarget::KeyEvent {
                    key: AndroidKey::VolumeUp,
                },
                "transport-failure",
                expires_at_unix_ms,
            ),
            Err(PhoneTargetFailure::Lifecycle(reason))
        );
        assert!(stopped.load(Ordering::Acquire));
        assert_eq!(live.backend.session_generation(), 2);
    }
}

#[test]
fn ordinary_phone_target_nonzero_is_action_only_and_keeps_the_session() {
    let stopped = Arc::new(AtomicBool::new(false));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let mut live = live_runtime_with_runner(
        Box::new(BlockingSession {
            target: Arc::new(Mutex::new(None)),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities: Arc::new(Mutex::new(Vec::new())),
        }),
        PhoneTargetRunner {
            result: Ok(CommandOutput { succeeded: false }),
            requests: Arc::clone(&requests),
        },
        requests,
    );
    let expires_at_unix_ms = u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock after epoch")
            .as_millis(),
    )
    .expect("current time fits u64")
        + 1_000;

    assert_eq!(
        live.backend.phone_target(
            PhoneTarget::KeyEvent {
                key: AndroidKey::VolumeUp,
            },
            "ordinary-failure",
            expires_at_unix_ms,
        ),
        Err(PhoneTargetFailure::ActionOnly(
            ActionFailureCode::TargetFailed
        ))
    );
    assert!(!stopped.load(Ordering::Acquire));
    assert_eq!(live.backend.session_generation(), 1);
}

#[test]
fn live_sessions_reject_qr_and_manual_pairing_without_state_change() {
    let stopped = Arc::new(AtomicBool::new(false));
    let live = live_runtime(
        Box::new(BlockingSession {
            target: Arc::new(Mutex::new(None)),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities: Arc::new(Mutex::new(Vec::new())),
        }),
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );
    let original_sink_events = live.sink.lines.lock().expect("memory sink lock").len();
    let mut engine = ProtocolEngine::new(live.backend, HELPER_EPOCH);

    for command in [
        r#"{"version":11,"type":"start-qr-pairing","helperEpoch":"73001"}"#,
        r#"{"version":11,"type":"submit-manual-code","helperEpoch":"73001","code":"123456"}"#,
    ] {
        assert_eq!(
            engine
                .handle_line(command)
                .into_iter()
                .map(|event| event.to_line())
                .collect::<Vec<_>>(),
            [
                r#"{"version":11,"type":"protocol-error","helperEpoch":"73001","reason":"invalid-command"}"#
            ]
        );
        engine.response_emitted();
    }

    let backend = engine.into_backend();
    assert_eq!(backend.session_generation(), 1);
    assert!(!stopped.load(Ordering::Acquire));
    assert_eq!(live.requests.lock().expect("request lock").len(), 1);
    assert_eq!(
        live.sink.lines.lock().expect("memory sink lock").len(),
        original_sink_events
    );
    assert!(!live.runtime_directory.exists());
}

#[test]
fn start_over_persistence_failure_preserves_the_live_session_and_trusted_state() {
    let stopped = Arc::new(AtomicBool::new(false));
    let live = live_runtime(
        Box::new(BlockingSession {
            target: Arc::new(Mutex::new(None)),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities: Arc::new(Mutex::new(Vec::new())),
        }),
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );
    let saved_state = live.state_directory.with_extension("saved");
    fs::rename(&live.state_directory, &saved_state).expect("move state directory");
    fs::write(&live.state_directory, b"not a directory").expect("block state path");
    let mut engine = ProtocolEngine::new(live.backend, HELPER_EPOCH);

    assert_eq!(
        engine
            .handle_line(
                r#"{"version":11,"type":"start-over","helperEpoch":"73001","sessionGeneration":"1"}"#,
            )
            .into_iter()
            .map(|event| event.to_line())
            .collect::<Vec<_>>(),
        [
            r#"{"version":11,"type":"failure","helperEpoch":"73001","reason":"dependency-unavailable"}"#
        ]
    );

    let backend = engine.into_backend();
    assert_eq!(backend.session_generation(), 1);
    assert!(backend.has_trusted_device());
    assert!(!stopped.load(Ordering::Acquire));
    assert!(saved_state.join("trusted-device.json").is_file());
}

#[test]
fn spontaneous_session_end_cancels_the_session_token_before_terminal_event() {
    let captured_cancellation = Arc::new(Mutex::new(None));
    let (release, ending_release) = mpsc::channel();
    let mut live = live_runtime(
        Box::new(EndingSession {
            cancellation: Arc::clone(&captured_cancellation),
            release: ending_release,
        }),
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );
    live.backend
        .acknowledge_preview_ready(HELPER_EPOCH, 1)
        .expect("acknowledge current preview");
    release.send(()).expect("release ending session");

    live.sink.wait_for_event("session-ended", Some("2"));

    assert_eq!(live.backend.session_generation(), 2);
    assert!(
        captured_cancellation
            .lock()
            .expect("session cancellation lock")
            .as_ref()
            .is_some_and(CancellationToken::is_cancelled)
    );
}

#[test]
fn pre_ready_session_end_retries_once_on_the_next_generation_in_event_order() {
    let (session, release, runs) =
        controlled_session([Ok(SessionExit::Ended), Ok(SessionExit::Stopped)]);
    let live = live_runtime(
        session,
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );

    release.send(()).expect("release first session");
    live.sink.wait_for_event("session-started", Some("2"));

    assert_eq!(runs.load(Ordering::Acquire), 2);
    assert_eq!(
        live.sink.session_event_identities(),
        [
            ("session-starting".to_owned(), "1".to_owned()),
            ("session-started".to_owned(), "1".to_owned()),
            ("session-starting".to_owned(), "2".to_owned()),
            ("session-started".to_owned(), "2".to_owned()),
        ]
    );
}

#[test]
fn pre_ready_disconnection_retries_once_without_emitting_the_first_failure() {
    let (session, release, runs) =
        controlled_session([Err(SessionFailure::Disconnected), Ok(SessionExit::Stopped)]);
    let live = live_runtime(
        session,
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );

    release.send(()).expect("release first session");
    live.sink.wait_for_event("session-started", Some("2"));

    assert_eq!(runs.load(Ordering::Acquire), 2);
    assert_eq!(
        live.sink.session_event_identities(),
        [
            ("session-starting".to_owned(), "1".to_owned()),
            ("session-started".to_owned(), "1".to_owned()),
            ("session-starting".to_owned(), "2".to_owned()),
            ("session-started".to_owned(), "2".to_owned()),
        ]
    );
}

#[test]
fn claimed_retry_is_announced_before_stop_emits_the_next_terminal_generation() {
    let (session, release, _) =
        controlled_session([Ok(SessionExit::Ended), Ok(SessionExit::Stopped)]);
    let (sink, gate) = blocking_retry_sink();
    let mut live = live_runtime_with_retry_sink(session, sink);

    release.send(()).expect("release first session");
    gate.wait_until_blocked();
    thread::scope(|scope| {
        let backend = &mut live.backend;
        let stop = scope.spawn(move || backend.stop_session());
        gate.release();
        stop.join().expect("stop thread");
    });

    let generation_transitions = live
        .sink
        .events
        .session_event_identities()
        .into_iter()
        .filter(|(event_type, _)| event_type == "session-starting" || event_type == "session-ended")
        .collect::<Vec<_>>();

    assert_eq!(
        generation_transitions,
        [
            ("session-starting".to_owned(), "1".to_owned()),
            ("session-starting".to_owned(), "2".to_owned()),
        ]
    );
    assert_eq!(live.sink.events.event_count("session-ended", "3"), 0);
    assert_eq!(live.backend.session_generation(), 3);
}

#[test]
fn second_pre_ready_failure_is_terminal_without_a_second_retry() {
    let (session, release, runs) =
        controlled_session([Ok(SessionExit::Ended), Err(SessionFailure::Disconnected)]);
    let live = live_runtime(
        session,
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );

    release.send(()).expect("release first session");
    live.sink.wait_for_event("session-started", Some("2"));
    release.send(()).expect("release retry session");
    let failure = live.sink.wait_for_event("lifecycle-failure", Some("3"));
    let failure: serde_json::Value =
        serde_json::from_str(&failure).expect("terminal lifecycle failure");

    assert_eq!(runs.load(Ordering::Acquire), 2);
    assert_eq!(failure["reason"], "disconnected");
    assert_eq!(
        live.sink.session_event_identities(),
        [
            ("session-starting".to_owned(), "1".to_owned()),
            ("session-started".to_owned(), "1".to_owned()),
            ("session-starting".to_owned(), "2".to_owned()),
            ("session-started".to_owned(), "2".to_owned()),
            ("lifecycle-failure".to_owned(), "3".to_owned()),
        ]
    );
}

#[test]
fn dependency_unavailable_before_preview_ready_is_terminal_without_retry() {
    let (session, release, runs) = controlled_session([Err(SessionFailure::DependencyUnavailable)]);
    let live = live_runtime(
        session,
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );

    release.send(()).expect("release first session");
    let failure = live.sink.wait_for_event("lifecycle-failure", Some("2"));
    let failure: serde_json::Value =
        serde_json::from_str(&failure).expect("dependency lifecycle failure");

    assert_eq!(runs.load(Ordering::Acquire), 1);
    assert_eq!(failure["reason"], "dependency-unavailable");
    assert_eq!(
        live.sink.session_event_identities(),
        [
            ("session-starting".to_owned(), "1".to_owned()),
            ("session-started".to_owned(), "1".to_owned()),
            ("lifecycle-failure".to_owned(), "2".to_owned()),
        ]
    );
}

#[test]
fn session_end_after_preview_ready_is_terminal_without_retry() {
    let (session, release, runs) = controlled_session([Ok(SessionExit::Ended)]);
    let mut live = live_runtime(
        session,
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );
    live.backend
        .acknowledge_preview_ready(HELPER_EPOCH, 1)
        .expect("acknowledge current preview");

    release.send(()).expect("release ready session");
    live.sink.wait_for_event("session-ended", Some("2"));

    assert_eq!(runs.load(Ordering::Acquire), 1);
    assert_eq!(
        live.sink.session_event_identities(),
        [
            ("session-starting".to_owned(), "1".to_owned()),
            ("session-started".to_owned(), "1".to_owned()),
            ("session-ended".to_owned(), "2".to_owned()),
        ]
    );
}

#[test]
fn disconnection_after_preview_ready_is_terminal_without_retry() {
    let (session, release, runs) = controlled_session([Err(SessionFailure::Disconnected)]);
    let mut live = live_runtime(
        session,
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );
    live.backend
        .acknowledge_preview_ready(HELPER_EPOCH, 1)
        .expect("acknowledge current preview");

    release.send(()).expect("release ready session");
    let failure = live.sink.wait_for_event("lifecycle-failure", Some("2"));
    let failure: serde_json::Value =
        serde_json::from_str(&failure).expect("ready lifecycle failure");

    assert_eq!(runs.load(Ordering::Acquire), 1);
    assert_eq!(failure["reason"], "disconnected");
    assert_eq!(
        live.sink.session_event_identities(),
        [
            ("session-starting".to_owned(), "1".to_owned()),
            ("session-started".to_owned(), "1".to_owned()),
            ("lifecycle-failure".to_owned(), "2".to_owned()),
        ]
    );
}

#[test]
fn runtime_shutdown_reaps_the_live_session_runner() {
    let stopped = Arc::new(AtomicBool::new(false));
    let mut live = live_runtime(
        Box::new(BlockingSession {
            target: Arc::new(Mutex::new(None)),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities: Arc::new(Mutex::new(Vec::new())),
        }),
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );

    live.backend.shutdown();

    assert_eq!(live.backend.session_generation(), 2);
    assert!(stopped.load(Ordering::Acquire));
}

#[test]
fn dropping_a_live_runtime_reaps_the_session_runner() {
    let stopped = Arc::new(AtomicBool::new(false));
    let live = live_runtime(
        Box::new(BlockingSession {
            target: Arc::new(Mutex::new(None)),
            stopped: Arc::clone(&stopped),
            quality: VideoQuality::default(),
            qualities: Arc::new(Mutex::new(Vec::new())),
        }),
        VecDeque::from([Ok(CommandOutput { succeeded: true })]),
    );

    drop(live);

    assert!(stopped.load(Ordering::Acquire));
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
        RuntimeDependencies::new(
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
        ),
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
        RuntimeDependencies::new(
            FakeDiscovery {
                trusted_result: Err(DiscoveryFailure::NetworkUnavailable),
                requested_devices: Vec::new(),
            },
            FakeRunner {
                outputs: VecDeque::new(),
                requests: Vec::new(),
            },
            None,
        ),
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();

    let failure = sink.wait_for_event("lifecycle-failure", Some("2"));
    let failure: serde_json::Value =
        serde_json::from_str(&failure).expect("lifecycle failure event");
    assert_eq!(failure["reason"], "disconnected");
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
        RuntimeDependencies::new(
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
        ),
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

    assert!(stopped.load(Ordering::Acquire));
    assert_eq!(sink.event_count("session-ended", "2"), 0);
}

#[test]
fn stop_session_waits_out_and_invalidates_an_in_flight_reconnect() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let state_directory = directory.path().join("state");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device"))
        .expect("seed trusted-device state");
    let started = Arc::new(AtomicBool::new(false));
    let target = Arc::new(Mutex::new(None));
    let stopped = Arc::new(AtomicBool::new(false));
    let sink = MemorySink::default();
    let mut backend = RuntimePairingBackend::with_dependencies(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
        sink.clone(),
        RuntimeDependencies::new(
            BlockingReconnectDiscovery {
                started: Arc::clone(&started),
            },
            FakeRunner {
                outputs: VecDeque::from([Ok(CommandOutput { succeeded: true })]),
                requests: Vec::new(),
            },
            Some(Box::new(BlockingSession {
                target: Arc::clone(&target),
                stopped: Arc::clone(&stopped),
                quality: VideoQuality::default(),
                qualities: Arc::new(Mutex::new(Vec::new())),
            })),
        ),
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    let started_deadline = Instant::now() + Duration::from_secs(1);
    while !started.load(Ordering::Acquire) {
        assert!(
            Instant::now() < started_deadline,
            "reconnect discovery did not start"
        );
        thread::sleep(Duration::from_millis(2));
    }

    backend.stop_session();

    assert_eq!(sink.event_count("connected", "1"), 0);
    assert_eq!(sink.event_count("session-started", "1"), 0);
    assert!(target.lock().expect("session target lock").is_none());
}

#[test]
fn stop_session_blocks_a_worker_that_already_holds_the_session_runner() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let state_directory = directory.path().join("state");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device"))
        .expect("seed trusted-device state");
    let quality_update_started = Arc::new(AtomicBool::new(false));
    let release_quality_update = Arc::new(AtomicBool::new(false));
    let run_called = Arc::new(AtomicBool::new(false));
    let sink = MemorySink::default();
    let mut backend = RuntimePairingBackend::with_dependencies(
        directory.path().join("runtime"),
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
        sink.clone(),
        RuntimeDependencies::new(
            FakeDiscovery {
                trusted_result: PairingEndpoint::new("192.168.50.4", 37_123)
                    .map_err(|_| DiscoveryFailure::NetworkUnavailable),
                requested_devices: Vec::new(),
            },
            FakeRunner {
                outputs: VecDeque::from([Ok(CommandOutput { succeeded: true })]),
                requests: Vec::new(),
            },
            Some(Box::new(BlockingQualitySession {
                quality_update_started: Arc::clone(&quality_update_started),
                release_quality_update: Arc::clone(&release_quality_update),
                run_called: Arc::clone(&run_called),
            })),
        ),
    )
    .expect("runtime backend");
    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();

    let started_deadline = Instant::now() + Duration::from_secs(1);
    while !quality_update_started.load(Ordering::Acquire) {
        assert!(
            Instant::now() < started_deadline,
            "session worker did not enter the quality update"
        );
        thread::sleep(Duration::from_millis(2));
    }

    let release_for_thread = Arc::clone(&release_quality_update);
    let releaser = thread::spawn(move || {
        thread::sleep(Duration::from_millis(50));
        release_for_thread.store(true, Ordering::Release);
    });
    backend.stop_session();
    releaser.join().expect("release session worker");
    thread::sleep(Duration::from_millis(25));

    assert!(!run_called.load(Ordering::Acquire));
    assert_eq!(sink.event_count("session-starting", "1"), 0);
    assert_eq!(sink.event_count("session-started", "1"), 0);
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
        RuntimeDependencies::new(
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
        ),
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
        RuntimeDependencies::new(
            FakeDiscovery {
                trusted_result: Err(DiscoveryFailure::NetworkUnavailable),
                requested_devices: Vec::new(),
            },
            FakeRunner {
                outputs: VecDeque::new(),
                requests: Vec::new(),
            },
            None,
        ),
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
        RuntimeDependencies::new(
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
        ),
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
        RuntimeDependencies::new(
            FakeDiscovery {
                trusted_result: Err(DiscoveryFailure::NetworkUnavailable),
                requested_devices: Vec::new(),
            },
            FakeRunner {
                outputs: VecDeque::new(),
                requests: Vec::new(),
            },
            None,
        ),
    );
    let error = match result {
        Ok(_) => panic!("symlinked state root was accepted"),
        Err(error) => error,
    };
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
}
