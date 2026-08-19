use std::{
    convert::Infallible,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant, SystemTime},
};

use omarchy_android_helper::{
    actions::PhoneTarget,
    input::{AndroidKey, DisplayGeometry, NormalizedPoint},
    persistence::{FileTrustedDeviceStore, TrustedDevice},
    process::{CancellationToken, CommandFailure, CommandOutput, CommandRequest, CommandRunner},
    protocol::{ActionFailureCode, Event, PairingBackend, PhoneTargetFailure},
    runtime::{ProtocolSink, RuntimeDependencies, RuntimePairingBackend},
    session::{PhysicalDisplaySize, SessionExit, SessionFailure, SessionRunner},
    wireless::{DiscoveryFailure, PairingEndpoint, WirelessDiscovery},
};

const HELPER_EPOCH: &str = "73001";

struct TrustedDiscovery {
    endpoint: PairingEndpoint,
}

impl WirelessDiscovery for TrustedDiscovery {
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
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        Ok(self.endpoint.clone())
    }
}

#[derive(Clone)]
struct SlowActionRunner {
    calls: Arc<AtomicUsize>,
    action_cancelled: Arc<AtomicBool>,
    action_reported_success: Arc<AtomicBool>,
}

impl CommandRunner for SlowActionRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        let call = self.calls.fetch_add(1, Ordering::AcqRel);
        if call == 0 {
            assert_eq!(request.arguments()[0], "connect");
            return Ok(CommandOutput { succeeded: true });
        }

        assert!(
            request
                .arguments()
                .iter()
                .any(|argument| argument == "monkey"),
            "bounded phone-target work must be the named app launch"
        );
        let would_report_success_at = Instant::now() + Duration::from_secs(4);
        loop {
            if cancellation.is_cancelled() {
                self.action_cancelled.store(true, Ordering::Release);
                return Err(CommandFailure::Cancelled);
            }
            if Instant::now() >= would_report_success_at {
                self.action_reported_success.store(true, Ordering::Release);
                return Ok(CommandOutput { succeeded: true });
            }
            thread::sleep(Duration::from_millis(2));
        }
    }
}

#[derive(Clone)]
struct SlowInputRunner {
    calls: Arc<AtomicUsize>,
    cancelled_calls: Arc<AtomicUsize>,
}

impl CommandRunner for SlowInputRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        let call = self.calls.fetch_add(1, Ordering::AcqRel);
        if call == 0 {
            assert_eq!(request.arguments()[0], "connect");
            return Ok(CommandOutput { succeeded: true });
        }
        if request
            .arguments()
            .iter()
            .any(|argument| argument == "swipe")
        {
            let completes_at = Instant::now() + Duration::from_millis(1_000);
            while Instant::now() < completes_at {
                if cancellation.is_cancelled() {
                    return Err(CommandFailure::Cancelled);
                }
                thread::sleep(Duration::from_millis(2));
            }
            return Ok(CommandOutput { succeeded: true });
        }

        assert!(
            request
                .arguments()
                .iter()
                .any(|argument| { argument == "keyevent" || argument == "disconnect" }),
            "unexpected synchronous command"
        );
        while !cancellation.is_cancelled() {
            thread::sleep(Duration::from_millis(2));
        }
        self.cancelled_calls.fetch_add(1, Ordering::AcqRel);
        Err(CommandFailure::Cancelled)
    }
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
    fn wait_for_event(&self, event_type: &str, generation: &str) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if self
                .lines
                .lock()
                .expect("memory sink lock")
                .iter()
                .any(|line| {
                    serde_json::from_str::<serde_json::Value>(line).is_ok_and(|value| {
                        value["type"] == event_type
                            && value["helperEpoch"] == HELPER_EPOCH
                            && value["sessionGeneration"] == generation
                    })
                })
            {
                return;
            }
            thread::sleep(Duration::from_millis(2));
        }
        panic!("event {event_type} at generation {generation} was not emitted");
    }
}

struct BlockingSession {
    stopped: Arc<AtomicBool>,
}

impl SessionRunner for BlockingSession {
    fn run(
        &mut self,
        _target: &str,
        cancellation: &CancellationToken,
        on_started: &mut dyn FnMut(Option<PhysicalDisplaySize>),
    ) -> Result<SessionExit, SessionFailure> {
        on_started(None);
        while !cancellation.is_cancelled() {
            thread::sleep(Duration::from_millis(2));
        }
        self.stopped.store(true, Ordering::Release);
        Ok(SessionExit::Stopped)
    }
}

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .expect("system time after Unix epoch")
        .as_millis()
        .try_into()
        .expect("Unix timestamp fits u64")
}

#[test]
fn runtime_rejects_invalid_phone_target_deadlines_and_bounds_accepted_work() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let runtime_directory = directory.path().join("runtime");
    let state_directory = directory.path().join("state");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device"))
        .expect("seed trusted-device state");

    let calls = Arc::new(AtomicUsize::new(0));
    let action_cancelled = Arc::new(AtomicBool::new(false));
    let action_reported_success = Arc::new(AtomicBool::new(false));
    let session_stopped = Arc::new(AtomicBool::new(false));
    let sink = MemorySink::default();
    let mut backend = RuntimePairingBackend::with_dependencies(
        &runtime_directory,
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
        sink.clone(),
        RuntimeDependencies::new(
            TrustedDiscovery {
                endpoint: PairingEndpoint::new("192.168.50.4", 37_123)
                    .expect("connection endpoint"),
            },
            SlowActionRunner {
                calls: Arc::clone(&calls),
                action_cancelled: Arc::clone(&action_cancelled),
                action_reported_success: Arc::clone(&action_reported_success),
            },
            Some(Box::new(BlockingSession {
                stopped: Arc::clone(&session_stopped),
            })),
        ),
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    sink.wait_for_event("session-started", "1");
    assert_eq!(calls.load(Ordering::Acquire), 1);

    assert_eq!(
        backend.phone_target(
            PhoneTarget::AppLaunch {
                package: "com.example.notes".to_owned(),
            },
            "expired-action",
            unix_time_ms() - 1_000,
        ),
        Err(PhoneTargetFailure::ActionOnly(
            ActionFailureCode::InvalidDeadline
        ))
    );
    assert_eq!(calls.load(Ordering::Acquire), 1);

    assert_eq!(
        backend.phone_target(
            PhoneTarget::AppLaunch {
                package: "com.example.notes".to_owned(),
            },
            "unreasonable-future-action",
            unix_time_ms() + 60_000,
        ),
        Err(PhoneTargetFailure::ActionOnly(
            ActionFailureCode::InvalidDeadline
        ))
    );
    assert_eq!(calls.load(Ordering::Acquire), 1);

    let started = Instant::now();
    assert_eq!(
        backend.phone_target(
            PhoneTarget::AppLaunch {
                package: "com.example.notes".to_owned(),
            },
            "slow-action",
            unix_time_ms() + 2_000,
        ),
        Err(PhoneTargetFailure::ActionOnly(
            ActionFailureCode::TargetTimedOut
        ))
    );
    assert!(
        started.elapsed() < Duration::from_millis(1_500),
        "the accepted target outlived its bounded execution window"
    );
    assert!(action_cancelled.load(Ordering::Acquire));
    assert!(!action_reported_success.load(Ordering::Acquire));
    assert_eq!(calls.load(Ordering::Acquire), 2);
    assert!(
        !session_stopped.load(Ordering::Acquire),
        "the child target deadline cancelled the active session"
    );

    backend.stop_session();
    assert!(session_stopped.load(Ordering::Acquire));
}

#[test]
fn runtime_bounds_input_and_start_over_disconnect_commands() {
    let directory = tempfile::tempdir().expect("temporary runtime");
    let runtime_directory = directory.path().join("runtime");
    let state_directory = directory.path().join("state");
    FileTrustedDeviceStore::new(&state_directory)
        .save(&TrustedDevice::new("adb-14141FD6F00081-TnSdi9").expect("trusted device"))
        .expect("seed trusted-device state");

    let calls = Arc::new(AtomicUsize::new(0));
    let cancelled_calls = Arc::new(AtomicUsize::new(0));
    let session_stopped = Arc::new(AtomicBool::new(false));
    let sink = MemorySink::default();
    let mut backend = RuntimePairingBackend::with_dependencies(
        &runtime_directory,
        &state_directory,
        Duration::from_secs(1),
        HELPER_EPOCH,
        sink.clone(),
        RuntimeDependencies::new(
            TrustedDiscovery {
                endpoint: PairingEndpoint::new("192.168.50.4", 37_123)
                    .expect("connection endpoint"),
            },
            SlowInputRunner {
                calls: Arc::clone(&calls),
                cancelled_calls: Arc::clone(&cancelled_calls),
            },
            Some(Box::new(BlockingSession {
                stopped: Arc::clone(&session_stopped),
            })),
        ),
    )
    .expect("runtime backend");

    backend
        .reconnect_trusted_device()
        .expect("queue trusted reconnect");
    backend.response_emitted();
    sink.wait_for_event("session-started", "1");

    let swipe_started = Instant::now();
    backend
        .pointer_swipe(
            DisplayGeometry::new(1080, 2400).expect("display geometry"),
            NormalizedPoint::new(0.2, 0.2).expect("swipe start"),
            NormalizedPoint::new(0.8, 0.8).expect("swipe end"),
            1_000,
        )
        .expect("long swipe remains within its duration-aware deadline");
    assert!(swipe_started.elapsed() >= Duration::from_millis(900));

    let input_started = Instant::now();
    assert_eq!(
        backend.key_input(AndroidKey::Back),
        Err(omarchy_android_helper::protocol::FailureReason::Disconnected)
    );
    assert!(input_started.elapsed() < Duration::from_millis(1_500));

    let start_over_started = Instant::now();
    backend.start_over().expect("start over completes");
    assert!(start_over_started.elapsed() < Duration::from_millis(1_500));
    assert_eq!(calls.load(Ordering::Acquire), 3);
    assert_eq!(cancelled_calls.load(Ordering::Acquire), 1);
    assert!(session_stopped.load(Ordering::Acquire));
}
