use std::{
    cell::{Cell, RefCell},
    convert::Infallible,
    fs,
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::Duration,
};

use omarchy_android_helper::qr::{
    Clock, EntropySource, QrArtifact, QrCeremony, QrRenderer, RuntimeQrRenderer,
};
use omarchy_android_helper::{
    process::{CommandFailure, CommandOutput, CommandRequest, CommandRunner},
    protocol::{Event, PROTOCOL_VERSION, PairingBackend, ProtocolEngine},
    runtime::{ProtocolSink, RuntimePairingBackend},
    wireless::{CancellationToken, DiscoveryFailure, PairingEndpoint, WirelessDiscovery},
};

struct SequenceEntropy {
    next: u8,
}

impl EntropySource for SequenceEntropy {
    type Error = Infallible;

    fn fill(&mut self, bytes: &mut [u8]) -> Result<(), Self::Error> {
        for byte in bytes {
            *byte = self.next;
            self.next = self.next.wrapping_add(1);
        }
        Ok(())
    }
}

#[derive(Clone)]
struct FakeClock {
    now: Rc<Cell<Duration>>,
}

impl Clock for FakeClock {
    fn now(&self) -> Duration {
        self.now.get()
    }
}

struct FakeArtifact {
    path: PathBuf,
    drops: Arc<AtomicUsize>,
}

impl QrArtifact for FakeArtifact {
    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for FakeArtifact {
    fn drop(&mut self) {
        self.drops.fetch_add(1, Ordering::SeqCst);
    }
}

struct FakeRenderer {
    payloads: Rc<RefCell<Vec<String>>>,
    drops: Arc<AtomicUsize>,
}

impl QrRenderer for FakeRenderer {
    type Artifact = FakeArtifact;
    type Error = Infallible;

    fn render(&mut self, payload: &str) -> Result<Self::Artifact, Self::Error> {
        let index = self.payloads.borrow().len();
        self.payloads.borrow_mut().push(payload.to_owned());
        Ok(FakeArtifact {
            path: PathBuf::from(format!("/runtime/qr-{index}.svg")),
            drops: Arc::clone(&self.drops),
        })
    }
}

fn ceremony(
    now: Rc<Cell<Duration>>,
    payloads: Rc<RefCell<Vec<String>>>,
    drops: Arc<AtomicUsize>,
) -> QrCeremony<SequenceEntropy, FakeClock, FakeRenderer> {
    QrCeremony::new(
        SequenceEntropy { next: 1 },
        FakeClock { now },
        FakeRenderer { payloads, drops },
        Duration::from_secs(120),
    )
}

#[test]
fn starts_an_android_qr_session_without_exposing_pairing_material() {
    let now = Rc::new(Cell::new(Duration::from_secs(10)));
    let payloads = Rc::new(RefCell::new(Vec::new()));
    let drops = Arc::new(AtomicUsize::new(0));
    let mut ceremony = ceremony(now, Rc::clone(&payloads), drops);

    let presentation = ceremony.start().expect("fake ceremony should start");

    assert_eq!(
        presentation.artifact_path,
        PathBuf::from("/runtime/qr-0.svg")
    );
    assert_eq!(presentation.expires_in_seconds, 120);
    assert!(ceremony.has_active_session());

    let payloads = payloads.borrow();
    assert_eq!(payloads.len(), 1);
    let (service, secret) = payloads[0]
        .strip_prefix("WIFI:T:ADB;S:")
        .and_then(|payload| payload.strip_suffix(";;"))
        .and_then(|payload| payload.split_once(";P:"))
        .expect("ADB QR payload fields");
    assert!(service.starts_with("studio-"));
    assert_eq!(service.len(), 17);
    assert_eq!(secret.len(), 10);
    assert!(service[7..].chars().chain(secret.chars()).all(|character| {
        character.is_ascii_alphanumeric() || character == '-' || character == '_'
    }));
}

#[test]
fn pairing_material_is_borrowed_only_while_the_session_is_active() {
    let now = Rc::new(Cell::new(Duration::ZERO));
    let payloads = Rc::new(RefCell::new(Vec::new()));
    let mut ceremony = ceremony(
        Rc::clone(&now),
        Rc::clone(&payloads),
        Arc::new(AtomicUsize::new(0)),
    );
    ceremony.start().expect("session");

    let reconstructed = ceremony
        .with_pairing_material(|service, secret| format!("WIFI:T:ADB;S:{service};P:{secret};;"))
        .expect("active pairing material");
    assert_eq!(reconstructed, payloads.borrow()[0]);

    ceremony.cancel();
    assert!(ceremony.with_pairing_material(|_, _| ()).is_none());

    ceremony.start().expect("second session");
    now.set(Duration::from_secs(120));
    assert!(ceremony.with_pairing_material(|_, _| ()).is_none());
}

#[test]
fn retry_replaces_the_artifact_and_pairing_material() {
    let now = Rc::new(Cell::new(Duration::ZERO));
    let payloads = Rc::new(RefCell::new(Vec::new()));
    let drops = Arc::new(AtomicUsize::new(0));
    let mut ceremony = ceremony(now, Rc::clone(&payloads), Arc::clone(&drops));

    let first = ceremony.start().expect("first session");
    let second = ceremony.start().expect("replacement session");

    assert_ne!(first.artifact_path, second.artifact_path);
    assert_ne!(payloads.borrow()[0], payloads.borrow()[1]);
    assert_eq!(drops.load(Ordering::SeqCst), 1);
}

#[test]
fn cancellation_and_expiry_drop_the_active_artifact() {
    let now = Rc::new(Cell::new(Duration::ZERO));
    let payloads = Rc::new(RefCell::new(Vec::new()));
    let drops = Arc::new(AtomicUsize::new(0));
    let mut ceremony = ceremony(Rc::clone(&now), payloads, Arc::clone(&drops));

    ceremony.start().expect("session");
    assert!(ceremony.cancel());
    assert!(!ceremony.has_active_session());
    assert_eq!(drops.load(Ordering::SeqCst), 1);

    ceremony.start().expect("second session");
    now.set(Duration::from_secs(119));
    assert!(!ceremony.expire_if_needed());
    now.set(Duration::from_secs(120));
    assert!(ceremony.expire_if_needed());
    assert!(!ceremony.has_active_session());
    assert_eq!(drops.load(Ordering::SeqCst), 2);
}

#[cfg(unix)]
#[test]
fn runtime_renderer_creates_a_private_ephemeral_svg() {
    use std::os::unix::fs::PermissionsExt;

    let directory = tempfile::tempdir().expect("temporary runtime directory");
    let mut renderer = RuntimeQrRenderer::new(directory.path());
    let artifact = renderer
        .render("WIFI:T:ADB;S:test-service;P:test-secret;;")
        .expect("render QR SVG");
    let path = artifact.path().to_owned();

    let metadata = fs::metadata(&path).expect("artifact metadata");
    assert_eq!(metadata.permissions().mode() & 0o077, 0);
    assert!(
        fs::read_to_string(&path)
            .expect("artifact SVG")
            .contains("<svg")
    );

    drop(artifact);
    assert!(!path.exists());
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

#[test]
fn runtime_backend_expires_the_artifact_and_emits_timeout() {
    let directory = tempfile::tempdir().expect("temporary runtime directory");
    let sink = MemorySink::default();
    let mut backend = RuntimePairingBackend::with_adapters(
        directory.path(),
        Duration::from_millis(20),
        sink.clone(),
        SequencedDiscovery {
            calls: Arc::new(AtomicUsize::new(0)),
        },
        SuccessfulRunner,
    )
    .expect("runtime QR backend");

    let presentation = backend.start_qr_pairing().expect("start QR pairing");
    backend.response_emitted();
    assert!(presentation.artifact.exists());

    for _ in 0..50 {
        if !sink.lines.lock().expect("memory sink lock").is_empty() {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }

    assert!(!presentation.artifact.exists());
    assert_eq!(
        *sink.lines.lock().expect("memory sink lock"),
        [Event::QrTimedOut.to_line()]
    );
}

struct SequencedDiscovery {
    calls: Arc<AtomicUsize>,
}

impl WirelessDiscovery for SequencedDiscovery {
    fn find_pairing_endpoint(
        &mut self,
        _requested_service: &str,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst);
        if call == 0 {
            while !cancellation.is_cancelled() {
                thread::sleep(Duration::from_millis(2));
            }
            return Err(DiscoveryFailure::Cancelled);
        }
        PairingEndpoint::new("pairing.local", 37_000)
            .map_err(|_| DiscoveryFailure::DependencyUnavailable)
    }

    fn find_connection_endpoint(
        &mut self,
        _pairing_endpoint: &PairingEndpoint,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        PairingEndpoint::new("connect.local", 38_000)
            .map_err(|_| DiscoveryFailure::DependencyUnavailable)
    }
}

struct SuccessfulRunner;

impl CommandRunner for SuccessfulRunner {
    fn run(
        &mut self,
        _request: CommandRequest,
        _cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        Ok(CommandOutput { succeeded: true })
    }
}

struct CancellationObservedDiscovery {
    started: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
}

impl WirelessDiscovery for CancellationObservedDiscovery {
    fn find_pairing_endpoint(
        &mut self,
        _requested_service: &str,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        self.started.store(true, Ordering::Release);
        while !cancellation.is_cancelled() {
            thread::sleep(Duration::from_millis(2));
        }
        self.finished.store(true, Ordering::Release);
        Err(DiscoveryFailure::Cancelled)
    }

    fn find_connection_endpoint(
        &mut self,
        _pairing_endpoint: &PairingEndpoint,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        Err(DiscoveryFailure::Cancelled)
    }
}

#[test]
fn cancellation_waits_for_the_active_worker_to_finish() {
    let directory = tempfile::tempdir().expect("temporary runtime directory");
    let started = Arc::new(AtomicBool::new(false));
    let finished = Arc::new(AtomicBool::new(false));
    let mut backend = RuntimePairingBackend::with_adapters(
        directory.path(),
        Duration::from_secs(1),
        MemorySink::default(),
        CancellationObservedDiscovery {
            started: Arc::clone(&started),
            finished: Arc::clone(&finished),
        },
        SuccessfulRunner,
    )
    .expect("runtime pairing backend");

    let presentation = backend.start_qr_pairing().expect("QR session");
    backend.response_emitted();
    while !started.load(Ordering::Acquire) {
        thread::sleep(Duration::from_millis(2));
    }

    backend.cancel_pairing();

    assert!(finished.load(Ordering::Acquire));
    assert!(!presentation.artifact.exists());
}

#[test]
fn replacement_suppresses_stale_worker_events() {
    let directory = tempfile::tempdir().expect("temporary runtime directory");
    let sink = MemorySink::default();
    let calls = Arc::new(AtomicUsize::new(0));
    let mut backend = RuntimePairingBackend::with_adapters(
        directory.path(),
        Duration::from_secs(1),
        sink.clone(),
        SequencedDiscovery {
            calls: Arc::clone(&calls),
        },
        SuccessfulRunner,
    )
    .expect("runtime pairing backend");

    let first = backend.start_qr_pairing().expect("first QR session");
    backend.response_emitted();
    for _ in 0..50 {
        if calls.load(Ordering::SeqCst) > 0 {
            break;
        }
        thread::sleep(Duration::from_millis(2));
    }
    assert!(calls.load(Ordering::SeqCst) > 0);

    let second = backend.start_qr_pairing().expect("replacement QR session");
    backend.response_emitted();
    assert!(!first.artifact.exists());

    for _ in 0..100 {
        if sink.lines.lock().expect("memory sink lock").len() >= 2 {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }

    assert_eq!(
        *sink.lines.lock().expect("memory sink lock"),
        [
            Event::Pairing {
                method: omarchy_android_helper::protocol::PairingMethod::Qr,
            }
            .to_line(),
            Event::Paired.to_line(),
        ]
    );
    assert!(!second.artifact.exists());
}

struct ManualDiscovery;

impl WirelessDiscovery for ManualDiscovery {
    fn find_pairing_endpoint(
        &mut self,
        _requested_service: &str,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        Err(DiscoveryFailure::DependencyUnavailable)
    }

    fn find_manual_pairing_endpoint(
        &mut self,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        PairingEndpoint::new("manual.local", 39_000)
            .map_err(|_| DiscoveryFailure::DependencyUnavailable)
    }

    fn find_connection_endpoint(
        &mut self,
        _pairing_endpoint: &PairingEndpoint,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        PairingEndpoint::new("connect.local", 39_001)
            .map_err(|_| DiscoveryFailure::DependencyUnavailable)
    }
}

#[test]
fn manual_worker_starts_after_the_synchronous_pairing_event() {
    let directory = tempfile::tempdir().expect("temporary runtime directory");
    let sink = MemorySink::default();
    let backend = RuntimePairingBackend::with_adapters(
        directory.path(),
        Duration::from_secs(1),
        sink.clone(),
        ManualDiscovery,
        SuccessfulRunner,
    )
    .expect("runtime pairing backend");
    let mut engine = ProtocolEngine::new(backend);

    let responses = engine.handle_line(&format!(
        r#"{{"version":{PROTOCOL_VERSION},"type":"submit-manual-code","code":"482913"}}"#
    ));
    assert!(sink.lines.lock().expect("memory sink lock").is_empty());
    for response in responses {
        sink.emit_line(&response).expect("synchronous response");
    }
    engine.response_emitted();

    for _ in 0..100 {
        if sink.lines.lock().expect("memory sink lock").len() >= 2 {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        *sink.lines.lock().expect("memory sink lock"),
        [
            Event::Pairing {
                method: omarchy_android_helper::protocol::PairingMethod::ManualCode,
            }
            .to_line(),
            Event::Paired.to_line(),
        ]
    );
}
