use std::{
    env,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::Duration,
};

use zeroize::Zeroizing;

use crate::{
    input::{AdbInputAdapter, AndroidKey, DisplayGeometry, InputFailure, NormalizedPoint},
    persistence::{FileTrustedDeviceStore, TrustedDevice},
    preferences::{FileRenderPreferenceStore, RenderPreferences},
    process::{AdbCommandRunner, CancellationToken, CommandRunner},
    protocol::{Event, FailureReason, PairingBackend, PairingMethod, QrPresentation},
    qr::{QrCeremony, RuntimeQrRenderer, SystemClock, SystemEntropy},
    session::{ScrcpySessionRunner, SessionExit, SessionFailure, SessionRunner},
    wireless::{AvahiDiscovery, PairingFlow, WirelessDiscovery},
};

pub trait ProtocolSink: Clone + Send + 'static {
    type Error;

    fn emit_line(&self, line: &str) -> Result<(), Self::Error>;

    fn emit_event(&self, event: &Event) -> Result<(), Self::Error> {
        self.emit_line(&event.to_line())
    }
}

/// Mirrors already-redacted protocol events into an optional private
/// acceptance log. Command input and subprocess output never pass through it.
pub struct AcceptanceEventWriter<W, L> {
    protocol: W,
    log: Option<L>,
}

impl<W, L> AcceptanceEventWriter<W, L> {
    #[must_use]
    pub fn without_log(protocol: W) -> Self {
        Self {
            protocol,
            log: None,
        }
    }

    #[must_use]
    pub fn with_log(protocol: W, log: L) -> Self {
        Self {
            protocol,
            log: Some(log),
        }
    }

    #[must_use]
    pub fn into_parts(self) -> (W, Option<L>) {
        (self.protocol, self.log)
    }
}

impl<W, L> Write for AcceptanceEventWriter<W, L>
where
    W: Write,
    L: Write,
{
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.protocol.write_all(buffer)?;
        if let Some(log) = self.log.as_mut() {
            log.write_all(buffer)?;
        }
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.protocol.flush()?;
        if let Some(log) = self.log.as_mut() {
            log.flush()?;
        }
        Ok(())
    }
}

pub struct WriterProtocolSink<W> {
    writer: Arc<Mutex<W>>,
}

impl<W> WriterProtocolSink<W> {
    #[must_use]
    pub fn new(writer: W) -> Self {
        Self {
            writer: Arc::new(Mutex::new(writer)),
        }
    }
}

impl<W> Clone for WriterProtocolSink<W> {
    fn clone(&self) -> Self {
        Self {
            writer: Arc::clone(&self.writer),
        }
    }
}

impl<W> ProtocolSink for WriterProtocolSink<W>
where
    W: Write + Send + 'static,
{
    type Error = io::Error;

    fn emit_line(&self, line: &str) -> Result<(), Self::Error> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| io::Error::other("protocol output lock poisoned"))?;
        writeln!(writer, "{line}")?;
        writer.flush()
    }
}

type RuntimeCeremony = QrCeremony<SystemEntropy, SystemClock, RuntimeQrRenderer>;
type RuntimeFlow = PairingFlow<Box<dyn WirelessDiscovery + Send>, Box<dyn CommandRunner + Send>>;

struct PendingPairing {
    generation: u64,
    method: PairingMethod,
    requested_service: Option<Zeroizing<String>>,
    secret: Zeroizing<String>,
}

struct PendingReconnect {
    generation: u64,
    device: TrustedDevice,
}

pub struct RuntimePairingBackend<S> {
    ceremony: Arc<Mutex<RuntimeCeremony>>,
    flow: Arc<Mutex<RuntimeFlow>>,
    session: Arc<Mutex<Option<Box<dyn SessionRunner + Send>>>>,
    active_target: Arc<Mutex<Option<String>>>,
    lifetime: Duration,
    sink: S,
    generation: Arc<AtomicU64>,
    cancellation: CancellationToken,
    session_generation: Arc<AtomicU64>,
    session_cancellation: CancellationToken,
    pending: Option<PendingPairing>,
    store: FileTrustedDeviceStore,
    preference_store: FileRenderPreferenceStore,
    preferences: RenderPreferences,
    trusted_device: Arc<Mutex<Option<TrustedDevice>>>,
    pending_reconnect: Option<PendingReconnect>,
}

impl<S> RuntimePairingBackend<S>
where
    S: ProtocolSink,
{
    pub fn new(
        runtime_directory: impl AsRef<Path>,
        state_directory: impl AsRef<Path>,
        lifetime: Duration,
        sink: S,
    ) -> io::Result<Self> {
        let v4l2_sink = env::var_os("OMARCHY_ANDROID_V4L2_SINK")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/dev/video42"));
        let session: Box<dyn SessionRunner + Send> = Box::new(ScrcpySessionRunner::new(
            "scrcpy",
            v4l2_sink,
            Duration::from_millis(25),
        ));
        Self::with_components(
            runtime_directory,
            state_directory,
            lifetime,
            sink,
            AvahiDiscovery::new("avahi-browse", lifetime, Duration::from_millis(25)),
            AdbCommandRunner::new("adb", Duration::from_millis(25)),
            Some(session),
        )
    }

    pub fn with_adapters<D, R>(
        runtime_directory: impl AsRef<Path>,
        lifetime: Duration,
        sink: S,
        discovery: D,
        runner: R,
    ) -> io::Result<Self>
    where
        D: WirelessDiscovery + Send + 'static,
        R: CommandRunner + Send + 'static,
    {
        let runtime_directory = runtime_directory.as_ref().to_owned();
        let state_directory = runtime_directory.join("state");
        Self::with_components(
            runtime_directory,
            state_directory,
            lifetime,
            sink,
            discovery,
            runner,
            None,
        )
    }

    pub fn with_adapters_and_store<D, R>(
        runtime_directory: impl AsRef<Path>,
        state_directory: impl AsRef<Path>,
        lifetime: Duration,
        sink: S,
        discovery: D,
        runner: R,
    ) -> io::Result<Self>
    where
        D: WirelessDiscovery + Send + 'static,
        R: CommandRunner + Send + 'static,
    {
        Self::with_components(
            runtime_directory,
            state_directory,
            lifetime,
            sink,
            discovery,
            runner,
            None,
        )
    }

    pub fn with_adapters_store_and_session<D, R, T>(
        runtime_directory: impl AsRef<Path>,
        state_directory: impl AsRef<Path>,
        lifetime: Duration,
        sink: S,
        discovery: D,
        runner: R,
        session: T,
    ) -> io::Result<Self>
    where
        D: WirelessDiscovery + Send + 'static,
        R: CommandRunner + Send + 'static,
        T: SessionRunner + Send + 'static,
    {
        Self::with_components(
            runtime_directory,
            state_directory,
            lifetime,
            sink,
            discovery,
            runner,
            Some(Box::new(session)),
        )
    }

    fn with_components<D, R>(
        runtime_directory: impl AsRef<Path>,
        state_directory: impl AsRef<Path>,
        lifetime: Duration,
        sink: S,
        discovery: D,
        runner: R,
        mut session: Option<Box<dyn SessionRunner + Send>>,
    ) -> io::Result<Self>
    where
        D: WirelessDiscovery + Send + 'static,
        R: CommandRunner + Send + 'static,
    {
        let ceremony = QrCeremony::new(
            SystemEntropy::new()?,
            SystemClock::new(),
            RuntimeQrRenderer::new(runtime_directory.as_ref()),
            lifetime,
        );
        let store = FileTrustedDeviceStore::new(&state_directory);
        let trusted_device = store.load()?;
        let preference_store = FileRenderPreferenceStore::new(&state_directory);
        let preferences = preference_store.load()?;
        if let Some(runner) = session.as_mut() {
            runner.set_quality(preferences.video_quality);
        }
        Ok(Self {
            ceremony: Arc::new(Mutex::new(ceremony)),
            flow: Arc::new(Mutex::new(PairingFlow::new(
                Box::new(discovery),
                Box::new(runner),
            ))),
            session: Arc::new(Mutex::new(session)),
            active_target: Arc::new(Mutex::new(None)),
            lifetime,
            sink,
            generation: Arc::new(AtomicU64::new(0)),
            cancellation: CancellationToken::new(),
            session_generation: Arc::new(AtomicU64::new(0)),
            session_cancellation: CancellationToken::new(),
            pending: None,
            store,
            preference_store,
            preferences,
            trusted_device: Arc::new(Mutex::new(trusted_device)),
            pending_reconnect: None,
        })
    }

    fn reset_session(&mut self) {
        self.session_cancellation.cancel();
        self.session_generation.fetch_add(1, Ordering::AcqRel);
        if let Ok(session) = self.session.lock() {
            drop(session);
        }
        if let Ok(mut target) = self.active_target.lock() {
            *target = None;
        }
        self.session_cancellation = CancellationToken::new();
    }

    fn run_input(
        &mut self,
        operation: impl FnOnce(&mut AdbInputAdapter<'_>, &str) -> Result<(), InputFailure>,
    ) -> Result<(), FailureReason> {
        let target = self
            .active_target
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?
            .clone()
            .ok_or(FailureReason::Disconnected)?;
        let mut flow = self
            .flow
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        let mut adapter =
            AdbInputAdapter::new(flow.runner_mut().as_mut(), &self.session_cancellation);
        operation(&mut adapter, &target).map_err(|failure| match failure {
            InputFailure::DependencyUnavailable => FailureReason::DependencyUnavailable,
            InputFailure::Disconnected | InputFailure::Cancelled => FailureReason::Disconnected,
        })
    }

    fn restart_session(&mut self, target: String) -> Result<(), FailureReason> {
        self.reset_session();
        self.session
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?
            .as_mut()
            .ok_or(FailureReason::DependencyUnavailable)?
            .set_quality(self.preferences.video_quality);
        let expected_generation = self.session_generation.fetch_add(1, Ordering::AcqRel) + 1;
        Self::spawn_session(
            Arc::clone(&self.session),
            Arc::clone(&self.session_generation),
            expected_generation,
            self.session_cancellation.clone(),
            self.sink.clone(),
            Arc::clone(&self.active_target),
            target,
        );
        Ok(())
    }

    fn spawn_session(
        session: Arc<Mutex<Option<Box<dyn SessionRunner + Send>>>>,
        generation: Arc<AtomicU64>,
        expected_generation: u64,
        cancellation: CancellationToken,
        sink: S,
        active_target: Arc<Mutex<Option<String>>>,
        target: String,
    ) {
        thread::spawn(move || {
            if cancellation.is_cancelled()
                || generation.load(Ordering::Acquire) != expected_generation
            {
                return;
            }
            let result = match session.lock() {
                Ok(mut session) => match session.as_mut() {
                    Some(runner) => {
                        if let Ok(mut active) = active_target.lock() {
                            *active = Some(target.clone());
                        } else {
                            return;
                        }
                        let _ = sink.emit_event(&Event::SessionStarting);
                        runner.run(&target, &cancellation, &mut || {
                            if !cancellation.is_cancelled()
                                && generation.load(Ordering::Acquire) == expected_generation
                            {
                                let _ = sink.emit_event(&Event::SessionStarted);
                            }
                        })
                    }
                    None => return,
                },
                Err(_) => Err(SessionFailure::DependencyUnavailable),
            };
            if generation
                .compare_exchange(
                    expected_generation,
                    expected_generation + 1,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_err()
            {
                return;
            }
            let event = match result {
                Ok(SessionExit::Ended) => Some(Event::SessionEnded),
                Ok(SessionExit::Stopped) => None,
                Err(SessionFailure::DependencyUnavailable) => Some(Event::Failure {
                    reason: FailureReason::DependencyUnavailable,
                }),
                Err(SessionFailure::Disconnected) => Some(Event::Failure {
                    reason: FailureReason::Disconnected,
                }),
            };
            if let Ok(mut active) = active_target.lock() {
                *active = None;
            }
            if let Some(event) = event {
                let _ = sink.emit_event(&event);
            }
        });
    }

    fn launch_pending(&mut self) {
        let Some(pending) = self.pending.take() else {
            return;
        };
        let pending_generation = pending.generation;
        let pending_method = pending.method;

        let flow = Arc::clone(&self.flow);
        let ceremony = Arc::clone(&self.ceremony);
        let generation = Arc::clone(&self.generation);
        let cancellation = self.cancellation.clone();
        let sink = self.sink.clone();
        let store = self.store.clone();
        let trusted_device = Arc::clone(&self.trusted_device);
        let session = Arc::clone(&self.session);
        let active_target = Arc::clone(&self.active_target);
        let session_generation = Arc::clone(&self.session_generation);
        let expected_session_generation =
            self.session_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let session_cancellation = self.session_cancellation.clone();
        let worker_cancellation = cancellation.clone();
        thread::spawn(move || {
            let mut terminal_event = None;
            let mut paired_device = None;
            let mut connected_target = None;
            match flow.lock() {
                Ok(mut flow) => {
                    let mut capture = |event| match event {
                        event @ Event::Pairing { .. } => {
                            if generation.load(Ordering::Acquire) == pending_generation {
                                let _ = sink.emit_event(&event);
                            }
                        }
                        event => terminal_event = Some(event),
                    };
                    if let Some(requested_service) = pending.requested_service.as_ref() {
                        flow.pair_with(
                            pending.method,
                            requested_service.as_str(),
                            pending.secret.as_str(),
                            &worker_cancellation,
                            &mut capture,
                        );
                    } else {
                        flow.pair_manual_with(
                            pending.secret.as_str(),
                            &worker_cancellation,
                            &mut capture,
                        );
                    }
                    paired_device = flow.take_paired_device();
                    connected_target = flow.take_connected_target();
                }
                Err(_) => {
                    terminal_event = Some(Event::Failure {
                        reason: FailureReason::DependencyUnavailable,
                    });
                }
            }

            if generation
                .compare_exchange(
                    pending_generation,
                    pending_generation + 1,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_ok()
            {
                worker_cancellation.cancel();
                if let Ok(mut ceremony) = ceremony.lock() {
                    ceremony.cancel();
                }
                if matches!(terminal_event, Some(Event::Paired))
                    && let Some(device) = paired_device
                {
                    if store.save(&device).is_ok() {
                        if let Ok(mut remembered) = trusted_device.lock() {
                            *remembered = Some(device);
                        }
                    } else {
                        terminal_event = Some(Event::Failure {
                            reason: FailureReason::DependencyUnavailable,
                        });
                    }
                }
                let starts_session =
                    matches!(terminal_event, Some(Event::Paired)) && connected_target.is_some();
                if let Some(event) = terminal_event {
                    let _ = sink.emit_event(&event);
                }
                if starts_session {
                    Self::spawn_session(
                        session,
                        session_generation,
                        expected_session_generation,
                        session_cancellation,
                        sink,
                        active_target,
                        connected_target.expect("paired flow has a connection target"),
                    );
                }
            }
        });

        let ceremony = Arc::clone(&self.ceremony);
        let generation = Arc::clone(&self.generation);
        let sink = self.sink.clone();
        let lifetime = self.lifetime;
        thread::spawn(move || {
            thread::sleep(lifetime);
            if generation
                .compare_exchange(
                    pending_generation,
                    pending_generation + 1,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_ok()
            {
                cancellation.cancel();
                if let Ok(mut ceremony) = ceremony.lock() {
                    ceremony.cancel();
                }
                let event = if pending_method == PairingMethod::Qr {
                    Event::QrTimedOut
                } else {
                    Event::Failure {
                        reason: FailureReason::NetworkUnavailable,
                    }
                };
                let _ = sink.emit_event(&event);
            }
        });
    }

    fn launch_reconnect(&mut self) {
        let Some(pending) = self.pending_reconnect.take() else {
            return;
        };
        let flow = Arc::clone(&self.flow);
        let generation = Arc::clone(&self.generation);
        let cancellation = self.cancellation.clone();
        let worker_cancellation = cancellation.clone();
        let sink = self.sink.clone();
        let session = Arc::clone(&self.session);
        let active_target = Arc::clone(&self.active_target);
        let session_generation = Arc::clone(&self.session_generation);
        let expected_session_generation =
            self.session_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let session_cancellation = self.session_cancellation.clone();
        thread::spawn(move || {
            let mut terminal_event = None;
            let mut connected_target = None;
            match flow.lock() {
                Ok(mut flow) => {
                    flow.reconnect_with(&pending.device, &worker_cancellation, |event| {
                        terminal_event = Some(event);
                    });
                    connected_target = flow.take_connected_target();
                }
                Err(_) => {
                    terminal_event = Some(Event::Failure {
                        reason: FailureReason::DependencyUnavailable,
                    });
                }
            }
            if generation
                .compare_exchange(
                    pending.generation,
                    pending.generation + 1,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_ok()
            {
                worker_cancellation.cancel();
                let starts_session =
                    matches!(terminal_event, Some(Event::Connected)) && connected_target.is_some();
                if let Some(event) = terminal_event {
                    let _ = sink.emit_event(&event);
                }
                if starts_session {
                    Self::spawn_session(
                        session,
                        session_generation,
                        expected_session_generation,
                        session_cancellation,
                        sink,
                        active_target,
                        connected_target.expect("reconnect has a connection target"),
                    );
                }
            }
        });
    }
}

impl<S> PairingBackend for RuntimePairingBackend<S>
where
    S: ProtocolSink,
{
    fn start_qr_pairing(&mut self) -> Result<QrPresentation, FailureReason> {
        self.reset_session();
        self.cancellation.cancel();
        self.pending = None;
        self.pending_reconnect = None;
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.cancellation = CancellationToken::new();

        let (presentation, requested_service, secret) = {
            let mut ceremony = self
                .ceremony
                .lock()
                .map_err(|_| FailureReason::DependencyUnavailable)?;
            let presentation = ceremony
                .start()
                .map_err(|_| FailureReason::DependencyUnavailable)?;
            let (requested_service, secret) = ceremony
                .with_pairing_material(|requested_service, secret| {
                    (
                        Zeroizing::new(requested_service.to_owned()),
                        Zeroizing::new(secret.to_owned()),
                    )
                })
                .ok_or(FailureReason::DependencyUnavailable)?;
            (presentation, requested_service, secret)
        };
        self.pending = Some(PendingPairing {
            generation,
            method: PairingMethod::Qr,
            requested_service: Some(requested_service),
            secret,
        });

        Ok(QrPresentation {
            artifact: presentation.artifact_path,
            expires_in_seconds: presentation.expires_in_seconds,
        })
    }

    fn cancel_pairing(&mut self) {
        self.reset_session();
        self.pending = None;
        self.pending_reconnect = None;
        self.cancellation.cancel();
        self.generation.fetch_add(1, Ordering::AcqRel);
        // Pairing workers hold the flow lock until every child process has
        // observed cancellation and exited. Crossing this barrier makes the
        // synchronous cancellation response a reliable cleanup acknowledgement.
        if let Ok(flow) = self.flow.lock() {
            drop(flow);
        }
        if let Ok(mut ceremony) = self.ceremony.lock() {
            ceremony.cancel();
        }
    }

    fn submit_manual_code(&mut self, code: &str) -> Result<(), FailureReason> {
        self.reset_session();
        self.cancellation.cancel();
        self.pending = None;
        self.pending_reconnect = None;
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.cancellation = CancellationToken::new();
        self.pending = Some(PendingPairing {
            generation,
            method: PairingMethod::ManualCode,
            requested_service: None,
            secret: Zeroizing::new(code.to_owned()),
        });
        Ok(())
    }

    fn has_trusted_device(&self) -> bool {
        self.trusted_device
            .lock()
            .is_ok_and(|device| device.is_some())
    }

    fn reconnect_trusted_device(&mut self) -> Result<(), FailureReason> {
        let device = self
            .trusted_device
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?
            .clone()
            .ok_or(FailureReason::Disconnected)?;
        self.reset_session();
        self.cancellation.cancel();
        self.pending = None;
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.cancellation = CancellationToken::new();
        self.pending_reconnect = Some(PendingReconnect { generation, device });
        Ok(())
    }

    fn stop_session(&mut self) {
        self.session_cancellation.cancel();
        self.session_generation.fetch_add(1, Ordering::AcqRel);
        if let Ok(session) = self.session.lock() {
            drop(session);
        }
        if let Ok(mut target) = self.active_target.lock() {
            *target = None;
        }
    }

    fn pointer_tap(
        &mut self,
        geometry: DisplayGeometry,
        point: NormalizedPoint,
    ) -> Result<(), FailureReason> {
        self.run_input(|adapter, target| adapter.tap(target, geometry, point))
    }

    fn pointer_swipe(
        &mut self,
        geometry: DisplayGeometry,
        start: NormalizedPoint,
        end: NormalizedPoint,
        duration_ms: u32,
    ) -> Result<(), FailureReason> {
        self.run_input(|adapter, target| adapter.swipe(target, geometry, start, end, duration_ms))
    }

    fn key_input(&mut self, key: AndroidKey) -> Result<(), FailureReason> {
        self.run_input(|adapter, target| adapter.key(target, key))
    }

    fn text_input(&mut self, text: &str) -> Result<(), FailureReason> {
        self.run_input(|adapter, target| adapter.text(target, text))
    }

    fn render_preferences(&self) -> RenderPreferences {
        self.preferences
    }

    fn set_render_preferences(
        &mut self,
        preferences: RenderPreferences,
    ) -> Result<bool, FailureReason> {
        let quality_changed = preferences.video_quality != self.preferences.video_quality;
        let restart_target = quality_changed
            .then(|| {
                self.active_target
                    .lock()
                    .map_err(|_| FailureReason::DependencyUnavailable)
                    .map(|target| target.clone())
            })
            .transpose()?
            .flatten();

        self.preference_store
            .save(&preferences)
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        self.preferences = preferences;

        if let Some(target) = restart_target {
            self.restart_session(target)?;
            return Ok(true);
        }
        if quality_changed {
            let mut session = self
                .session
                .lock()
                .map_err(|_| FailureReason::DependencyUnavailable)?;
            if let Some(runner) = session.as_mut() {
                runner.set_quality(preferences.video_quality);
            }
        }
        Ok(false)
    }

    fn response_emitted(&mut self) {
        self.launch_reconnect();
        self.launch_pending();
    }
}

#[must_use]
pub fn default_runtime_directory() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir)
        .join("omarchy-android")
}
