use std::{
    env,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use zeroize::Zeroizing;

use crate::{
    actions::{AdbActionAdapter, PhoneTarget},
    input::{AdbInputAdapter, AndroidKey, DisplayGeometry, InputFailure, NormalizedPoint},
    persistence::{FileTrustedDeviceStore, TrustedDevice},
    preferences::{FilePreferenceStore, Preferences, VideoQuality},
    private_fs::ensure_private_directory,
    process::{
        ActionExecutionFailure, AdbCommandRunner, CancellationToken, CommandRequest, CommandRunner,
    },
    protocol::{
        ActionFailureCode, Event, FailureReason, PairingBackend, PairingEvent, PairingMethod,
        PairingRequestFailure, PhoneTargetFailure, QrPresentation,
    },
    qr::{QrCeremony, RuntimeQrRenderer, SystemClock, SystemEntropy},
    scrcpy_config::{FileScrcpyConfigStore, ScrcpyConfiguration},
    session::{ScrcpySessionRunner, SessionExit, SessionFailure, SessionRunner},
    wireless::{AvahiDiscovery, PairingFlow, WirelessDiscovery},
};

const MAX_PHONE_TARGET_DEADLINE_AHEAD_MS: u64 = 2_000;
const MAX_PHONE_TARGET_EXECUTION_MS: u64 = 750;
const MAX_LOCAL_COMMAND_MS: u64 = 750;

pub trait ProtocolSink: Clone + Send + 'static {
    type Error;

    fn emit_event(&self, event: &Event) -> Result<(), Self::Error>;
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

    fn emit_event(&self, event: &Event) -> Result<(), Self::Error> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| io::Error::other("protocol output lock poisoned"))?;
        writeln!(writer, "{}", event.to_line())?;
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

#[derive(Default)]
struct SessionTransition {
    preview_ready_generation: Option<u64>,
}

impl SessionTransition {
    fn acknowledge_preview_ready(
        &mut self,
        acknowledged_generation: u64,
        current_generation: u64,
    ) -> Result<(), FailureReason> {
        if acknowledged_generation != current_generation {
            return Err(FailureReason::Disconnected);
        }
        self.preview_ready_generation = Some(acknowledged_generation);
        Ok(())
    }

    fn claim_retry(
        &self,
        attempt_generation: u64,
        current_generation: u64,
        cancelled: bool,
    ) -> Option<u64> {
        (!cancelled
            && attempt_generation == current_generation
            && self.preview_ready_generation != Some(attempt_generation))
        .then(|| attempt_generation + 1)
    }
}

struct SessionControl {
    runner: Arc<Mutex<Option<Box<dyn SessionRunner + Send>>>>,
    target: Arc<Mutex<Option<String>>>,
    scrcpy_arguments: Arc<Mutex<Vec<String>>>,
    generation: Arc<AtomicU64>,
    transition: Arc<Mutex<SessionTransition>>,
    cancellation: CancellationToken,
    helper_epoch: String,
}

impl SessionControl {
    fn start<S>(&self, quality: VideoQuality, sink: S) -> impl FnOnce(String, u64) + Send + 'static
    where
        S: ProtocolSink,
    {
        let runner = Arc::clone(&self.runner);
        let target = Arc::clone(&self.target);
        let scrcpy_arguments = Arc::clone(&self.scrcpy_arguments);
        let generation = Arc::clone(&self.generation);
        let transition = Arc::clone(&self.transition);
        let cancellation = self.cancellation.clone();
        let helper_epoch = self.helper_epoch.clone();
        move |connected_target, expected_generation| {
            thread::spawn(move || {
                if cancellation.is_cancelled()
                    || generation.load(Ordering::Acquire) != expected_generation
                {
                    return;
                }
                let configured_arguments = match scrcpy_arguments.lock() {
                    Ok(arguments) => arguments.clone(),
                    Err(_) => return,
                };
                let screen_off_enabled = configured_arguments
                    .iter()
                    .any(|argument| argument == "--turn-screen-off");
                let mut current_generation = expected_generation;
                let mut retried = false;
                let result = match runner.lock() {
                    Ok(mut runner) => {
                        let Some(session) = runner.as_mut() else {
                            return;
                        };
                        session.set_quality(quality);
                        session.set_scrcpy_arguments(configured_arguments);
                        if let Ok(mut active) = target.lock() {
                            *active = Some(connected_target.clone());
                        } else {
                            return;
                        }
                        let mut session_generation = current_generation.to_string();
                        {
                            let Ok(_transition) = transition.lock() else {
                                return;
                            };
                            if cancellation.is_cancelled()
                                || generation.load(Ordering::Acquire) != current_generation
                            {
                                return;
                            }
                            let _ = sink.emit_event(&Event::SessionStarting {
                                helper_epoch: helper_epoch.clone(),
                                session_generation: session_generation.clone(),
                            });
                        }
                        loop {
                            let result = session.run(
                                &connected_target,
                                &cancellation,
                                &mut |physical_display| {
                                    if !cancellation.is_cancelled()
                                        && generation.load(Ordering::Acquire) == current_generation
                                    {
                                        let _ = sink.emit_event(&Event::SessionStarted {
                                            helper_epoch: helper_epoch.clone(),
                                            session_generation: session_generation.clone(),
                                            physical_width_mm: physical_display
                                                .map(|size| size.width_mm()),
                                            physical_height_mm: physical_display
                                                .map(|size| size.height_mm()),
                                            screen_off_enabled,
                                        });
                                    }
                                },
                            );
                            if !retried
                                && matches!(
                                    &result,
                                    Ok(SessionExit::Ended) | Err(SessionFailure::Disconnected)
                                )
                            {
                                let Ok(transition) = transition.lock() else {
                                    return;
                                };
                                let observed_generation = generation.load(Ordering::Acquire);
                                if observed_generation != current_generation {
                                    return;
                                }
                                if let Some(retry_generation) = transition.claim_retry(
                                    current_generation,
                                    observed_generation,
                                    cancellation.is_cancelled(),
                                ) {
                                    if generation
                                        .compare_exchange(
                                            current_generation,
                                            retry_generation,
                                            Ordering::AcqRel,
                                            Ordering::Acquire,
                                        )
                                        .is_err()
                                    {
                                        return;
                                    }
                                    current_generation = retry_generation;
                                    session_generation = current_generation.to_string();
                                    let _ = sink.emit_event(&Event::SessionStarting {
                                        helper_epoch: helper_epoch.clone(),
                                        session_generation: session_generation.clone(),
                                    });
                                    retried = true;
                                    drop(transition);
                                    continue;
                                }
                            }
                            break result;
                        }
                    }
                    Err(_) => Err(SessionFailure::DependencyUnavailable),
                };
                let ended_generation = current_generation + 1;
                {
                    let Ok(_transition) = transition.lock() else {
                        return;
                    };
                    if cancellation.is_cancelled()
                        || generation
                            .compare_exchange(
                                current_generation,
                                ended_generation,
                                Ordering::AcqRel,
                                Ordering::Acquire,
                            )
                            .is_err()
                    {
                        return;
                    }
                    cancellation.cancel();
                }
                if let Ok(mut active) = target.lock() {
                    *active = None;
                }
                let session_generation = ended_generation.to_string();
                let event = match result {
                    Ok(SessionExit::Ended | SessionExit::Stopped) => Event::SessionEnded {
                        helper_epoch,
                        session_generation,
                    },
                    Err(SessionFailure::DependencyUnavailable) => Event::LifecycleFailure {
                        helper_epoch,
                        session_generation,
                        reason: FailureReason::DependencyUnavailable,
                    },
                    Err(SessionFailure::Disconnected) => Event::LifecycleFailure {
                        helper_epoch,
                        session_generation,
                        reason: FailureReason::Disconnected,
                    },
                };
                let _ = sink.emit_event(&event);
            });
        }
    }

    fn stop_and_wait(&mut self) {
        let transition = self.transition.lock();
        self.cancellation.cancel();
        drop(transition);
        self.wait_and_reset();
    }

    fn invalidate_and_wait(&mut self) -> u64 {
        let transition = self.transition.lock();
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.cancellation.cancel();
        drop(transition);
        self.wait_and_reset();
        generation
    }

    fn wait_and_reset(&mut self) {
        if let Ok(session) = self.runner.lock() {
            drop(session);
        }
        if let Ok(mut target) = self.target.lock() {
            *target = None;
        }
        self.cancellation = CancellationToken::new();
    }

    fn set_scrcpy_arguments(&self, arguments: Vec<String>) -> Result<(), FailureReason> {
        *self
            .scrcpy_arguments
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)? = arguments;
        Ok(())
    }

    fn restart<S>(
        &mut self,
        target: String,
        quality: VideoQuality,
        sink: S,
    ) -> Result<(), FailureReason>
    where
        S: ProtocolSink,
    {
        let generation = self.invalidate_and_wait();
        if self
            .runner
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?
            .is_none()
        {
            return Err(FailureReason::DependencyUnavailable);
        }
        self.start(quality, sink)(target, generation);
        Ok(())
    }

    fn target(&self) -> Result<Option<String>, FailureReason> {
        self.target
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)
            .map(|target| target.clone())
    }

    fn child_cancellation(&self) -> CancellationToken {
        self.cancellation.clone()
    }

    fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    fn acknowledge_preview_ready(&self, session_generation: u64) -> Result<(), FailureReason> {
        let mut transition = self
            .transition
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        let current_generation = self.generation.load(Ordering::Acquire);
        transition.acknowledge_preview_ready(session_generation, current_generation)
    }
}

pub struct RuntimeDependencies<D, R> {
    discovery: D,
    runner: R,
    session: Option<Box<dyn SessionRunner + Send>>,
}

impl<D, R> RuntimeDependencies<D, R> {
    pub fn new(discovery: D, runner: R, session: Option<Box<dyn SessionRunner + Send>>) -> Self {
        Self {
            discovery,
            runner,
            session,
        }
    }
}

pub struct RuntimePairingBackend<S> {
    ceremony: Arc<Mutex<RuntimeCeremony>>,
    flow: Arc<Mutex<RuntimeFlow>>,
    session: SessionControl,
    lifetime: Duration,
    sink: S,
    helper_epoch: String,
    generation: Arc<AtomicU64>,
    cancellation: CancellationToken,
    pending: Option<PendingPairing>,
    store: FileTrustedDeviceStore,
    preference_store: FilePreferenceStore,
    preferences: Preferences,
    scrcpy_config_store: FileScrcpyConfigStore,
    effective_screen_off: bool,
    scrcpy_configuration: ScrcpyConfiguration,
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
        helper_epoch: impl Into<String>,
        sink: S,
    ) -> io::Result<Self> {
        let session: Box<dyn SessionRunner + Send> = Box::new(ScrcpySessionRunner::new_guarded(
            env::current_exe()?,
            Duration::from_millis(25),
        ));
        Self::with_dependencies(
            runtime_directory,
            state_directory,
            lifetime,
            helper_epoch,
            sink,
            RuntimeDependencies::new(
                AvahiDiscovery::new("avahi-browse", lifetime, Duration::from_millis(25)),
                AdbCommandRunner::new("adb", Duration::from_millis(25)),
                Some(session),
            ),
        )
    }

    pub fn with_dependencies<D, R>(
        runtime_directory: impl AsRef<Path>,
        state_directory: impl AsRef<Path>,
        lifetime: Duration,
        helper_epoch: impl Into<String>,
        sink: S,
        dependencies: RuntimeDependencies<D, R>,
    ) -> io::Result<Self>
    where
        D: WirelessDiscovery + Send + 'static,
        R: CommandRunner + Send + 'static,
    {
        let state_directory = state_directory.as_ref();
        ensure_private_directory(state_directory)?;
        let ceremony = QrCeremony::new(
            SystemEntropy::new()?,
            SystemClock::new(),
            RuntimeQrRenderer::new(runtime_directory.as_ref()),
            lifetime,
        );
        let store = FileTrustedDeviceStore::new(state_directory);
        let trusted_device = store.load()?;
        let preference_store = FilePreferenceStore::new(state_directory);
        let preferences = preference_store.load()?;
        let scrcpy_config_store = FileScrcpyConfigStore::new(state_directory);
        let scrcpy_configuration = scrcpy_config_store.load()?;
        let helper_epoch = helper_epoch.into();
        Ok(Self {
            ceremony: Arc::new(Mutex::new(ceremony)),
            flow: Arc::new(Mutex::new(PairingFlow::new(
                Box::new(dependencies.discovery),
                Box::new(dependencies.runner),
            ))),
            session: SessionControl {
                runner: Arc::new(Mutex::new(dependencies.session)),
                target: Arc::new(Mutex::new(None)),
                scrcpy_arguments: Arc::new(Mutex::new(
                    scrcpy_configuration.effective_arguments(false),
                )),
                generation: Arc::new(AtomicU64::new(0)),
                transition: Arc::new(Mutex::new(SessionTransition::default())),
                cancellation: CancellationToken::new(),
                helper_epoch: helper_epoch.clone(),
            },
            lifetime,
            sink,
            helper_epoch,
            generation: Arc::new(AtomicU64::new(0)),
            cancellation: CancellationToken::new(),
            pending: None,
            store,
            preference_store,
            preferences,
            scrcpy_config_store,
            scrcpy_configuration,
            effective_screen_off: false,
            trusted_device: Arc::new(Mutex::new(trusted_device)),
            pending_reconnect: None,
        })
    }

    fn stop_for_pairing(&mut self) -> Result<(), PairingRequestFailure> {
        if self
            .session
            .target()
            .map_err(PairingRequestFailure::Backend)?
            .is_some()
        {
            return Err(PairingRequestFailure::InvalidState);
        }
        self.session.stop_and_wait();
        Ok(())
    }

    fn run_input(
        &mut self,
        timeout_ms: u64,
        operation: impl FnOnce(&mut AdbInputAdapter<'_>, &str) -> Result<(), InputFailure>,
    ) -> Result<(), FailureReason> {
        let cancellation = self
            .session
            .child_cancellation()
            .child_with_timeout(Duration::from_millis(timeout_ms));
        let result = self.run_input_with_cancellation(&cancellation, operation);
        if result.is_err() {
            self.session.invalidate_and_wait();
        }
        result
    }

    fn run_input_with_cancellation(
        &mut self,
        cancellation: &CancellationToken,
        operation: impl FnOnce(&mut AdbInputAdapter<'_>, &str) -> Result<(), InputFailure>,
    ) -> Result<(), FailureReason> {
        let target = self.session.target()?.ok_or(FailureReason::Disconnected)?;
        let mut flow = self
            .flow
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        let mut adapter = AdbInputAdapter::new(flow.runner_mut().as_mut(), cancellation);
        operation(&mut adapter, &target).map_err(|failure| match failure {
            InputFailure::DependencyUnavailable => FailureReason::DependencyUnavailable,
            InputFailure::Disconnected | InputFailure::Cancelled => FailureReason::Disconnected,
        })
    }

    fn prepare_session_start(&mut self) -> Result<(), FailureReason> {
        let effective_screen_off = self.scrcpy_configuration.screen_off_requested();
        self.effective_screen_off = effective_screen_off;
        self.session.set_scrcpy_arguments(
            self.scrcpy_configuration
                .effective_arguments(effective_screen_off),
        )
    }

    fn launch_pending(&mut self) {
        if self.pending.is_none() {
            return;
        }
        if self.prepare_session_start().is_err() {
            let _ = self.sink.emit_event(&Event::LifecycleFailure {
                helper_epoch: self.helper_epoch.clone(),
                session_generation: self.session.generation().to_string(),
                reason: FailureReason::DependencyUnavailable,
            });
            return;
        }
        let Some(pending) = self.pending.take() else {
            return;
        };
        let pending_generation = pending.generation;

        let public_generation = Arc::clone(&self.session.generation);
        let helper_epoch = self.helper_epoch.clone();
        let flow = Arc::clone(&self.flow);
        let ceremony = Arc::clone(&self.ceremony);
        let generation = Arc::clone(&self.generation);
        let cancellation = self.cancellation.clone();
        let sink = self.sink.clone();
        let store = self.store.clone();
        let trusted_device = Arc::clone(&self.trusted_device);
        let start_session = self
            .session
            .start(self.preferences.video_quality, self.sink.clone());
        let worker_cancellation = cancellation.clone();
        let progress_epoch = helper_epoch.clone();
        let progress_sink = sink.clone();
        thread::spawn(move || {
            let mut terminal_event = None;
            let mut paired_device = None;
            let mut connected_target = None;
            match flow.lock() {
                Ok(mut flow) => {
                    let mut capture = |event| match event {
                        PairingEvent::Pairing { method } => {
                            if generation.load(Ordering::Acquire) == pending_generation {
                                let _ = progress_sink.emit_event(&Event::Pairing {
                                    helper_epoch: progress_epoch.clone(),
                                    method,
                                });
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
                    terminal_event = Some(PairingEvent::Failure {
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
                if matches!(terminal_event, Some(PairingEvent::Paired))
                    && let Some(device) = paired_device
                {
                    if store.save(&device).is_ok() {
                        if let Ok(mut remembered) = trusted_device.lock() {
                            *remembered = Some(device);
                        }
                    } else {
                        terminal_event = Some(PairingEvent::Failure {
                            reason: FailureReason::DependencyUnavailable,
                        });
                    }
                }
                let paired = matches!(terminal_event, Some(PairingEvent::Paired));
                let starts_session = paired && connected_target.is_some();
                let event_generation = if paired {
                    public_generation.fetch_add(1, Ordering::AcqRel) + 1
                } else {
                    public_generation.load(Ordering::Acquire)
                };
                if let Some(event) = terminal_event {
                    let _ = sink.emit_event(&pairing_event(&helper_epoch, event_generation, event));
                }
                if starts_session && let Some(connected_target) = connected_target {
                    start_session(connected_target, event_generation);
                }
            } else if let Some(target) = connected_target {
                let disconnect = CancellationToken::new()
                    .child_with_timeout(Duration::from_millis(MAX_LOCAL_COMMAND_MS));
                if let Ok(mut flow) = flow.lock() {
                    let _ = flow.runner_mut().run(
                        CommandRequest::new("adb", vec!["disconnect".to_owned(), target]),
                        &disconnect,
                    );
                }
            }
        });

        let ceremony = Arc::clone(&self.ceremony);
        let generation = Arc::clone(&self.generation);
        let lifetime = self.lifetime;
        thread::spawn(move || {
            thread::sleep(lifetime);
            if generation.load(Ordering::Acquire) != pending_generation {
                return;
            }
            cancellation.cancel();
            if let Ok(mut ceremony) = ceremony.lock() {
                if generation.load(Ordering::Acquire) == pending_generation {
                    ceremony.cancel();
                }
            }
        });
    }
    fn launch_reconnect(&mut self) {
        if self.pending_reconnect.is_none() {
            return;
        }
        if self.prepare_session_start().is_err() {
            let _ = self.sink.emit_event(&Event::LifecycleFailure {
                helper_epoch: self.helper_epoch.clone(),
                session_generation: self.session.generation().to_string(),
                reason: FailureReason::DependencyUnavailable,
            });
            return;
        }
        let Some(pending) = self.pending_reconnect.take() else {
            return;
        };
        let flow = Arc::clone(&self.flow);
        let generation = Arc::clone(&self.generation);
        let session_generation = Arc::clone(&self.session.generation);
        let expected_session_generation = self.session.generation();
        let cancellation = self.cancellation.clone();
        let worker_cancellation = cancellation.clone();
        let sink = self.sink.clone();
        let helper_epoch = self.helper_epoch.clone();
        let start_session = self
            .session
            .start(self.preferences.video_quality, self.sink.clone());
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
                    terminal_event = Some(PairingEvent::Failure {
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
                let starts_session = matches!(terminal_event, Some(PairingEvent::Connected))
                    && connected_target.is_some();
                if let Some(event) = terminal_event {
                    let event = match event {
                        PairingEvent::Connected => Event::Connected {
                            helper_epoch: helper_epoch.clone(),
                            session_generation: expected_session_generation.to_string(),
                        },
                        PairingEvent::Failure { reason } => {
                            let failed_generation = expected_session_generation + 1;
                            if session_generation
                                .compare_exchange(
                                    expected_session_generation,
                                    failed_generation,
                                    Ordering::AcqRel,
                                    Ordering::Acquire,
                                )
                                .is_err()
                            {
                                return;
                            }
                            Event::LifecycleFailure {
                                helper_epoch: helper_epoch.clone(),
                                session_generation: failed_generation.to_string(),
                                reason,
                            }
                        }
                        PairingEvent::PairingCancelled => return,
                        PairingEvent::Pairing { .. }
                        | PairingEvent::QrTimedOut
                        | PairingEvent::Paired => Event::LifecycleFailure {
                            helper_epoch: helper_epoch.clone(),
                            session_generation: expected_session_generation.to_string(),
                            reason: FailureReason::DependencyUnavailable,
                        },
                    };
                    let _ = sink.emit_event(&event);
                }
                if starts_session && let Some(connected_target) = connected_target {
                    start_session(connected_target, expected_session_generation);
                }
            }
        });
    }
}

impl<S> Drop for RuntimePairingBackend<S> {
    fn drop(&mut self) {
        self.cancellation.cancel();
        self.generation.fetch_add(1, Ordering::AcqRel);
        if let Ok(flow) = self.flow.lock() {
            drop(flow);
        }
        if let Ok(mut ceremony) = self.ceremony.lock() {
            ceremony.cancel();
        }
        self.session.invalidate_and_wait();
    }
}

fn pairing_event(helper_epoch: &str, session_generation: u64, event: PairingEvent) -> Event {
    match event {
        PairingEvent::Pairing { method } => Event::Pairing {
            helper_epoch: helper_epoch.to_owned(),
            method,
        },
        PairingEvent::PairingCancelled => Event::PairingCancelled {
            helper_epoch: helper_epoch.to_owned(),
        },
        PairingEvent::QrTimedOut => Event::QrTimedOut {
            helper_epoch: helper_epoch.to_owned(),
        },
        PairingEvent::Paired => Event::Paired {
            helper_epoch: helper_epoch.to_owned(),
            session_generation: session_generation.to_string(),
        },
        PairingEvent::Connected => Event::Connected {
            helper_epoch: helper_epoch.to_owned(),
            session_generation: session_generation.to_string(),
        },
        PairingEvent::Failure { reason } => Event::Failure {
            helper_epoch: helper_epoch.to_owned(),
            reason,
        },
    }
}

impl<S> PairingBackend for RuntimePairingBackend<S>
where
    S: ProtocolSink,
{
    fn start_qr_pairing(&mut self) -> Result<QrPresentation, PairingRequestFailure> {
        self.stop_for_pairing()?;
        self.cancellation.cancel();
        self.pending = None;
        self.pending_reconnect = None;
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.cancellation = CancellationToken::new();

        let (presentation, requested_service, secret) = {
            let mut ceremony = self.ceremony.lock().map_err(|_| {
                PairingRequestFailure::Backend(FailureReason::DependencyUnavailable)
            })?;
            let presentation = ceremony.start().map_err(|_| {
                PairingRequestFailure::Backend(FailureReason::DependencyUnavailable)
            })?;
            let (requested_service, secret) = ceremony
                .with_pairing_material(|requested_service, secret| {
                    (
                        Zeroizing::new(requested_service.to_owned()),
                        Zeroizing::new(secret.to_owned()),
                    )
                })
                .ok_or(PairingRequestFailure::Backend(
                    FailureReason::DependencyUnavailable,
                ))?;
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

    fn submit_manual_code(&mut self, code: &str) -> Result<(), PairingRequestFailure> {
        self.stop_for_pairing()?;
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
        if let Ok(mut ceremony) = self.ceremony.lock() {
            ceremony.cancel();
        }
        Ok(())
    }

    fn has_trusted_device(&self) -> bool {
        self.trusted_device
            .lock()
            .is_ok_and(|device| device.is_some())
    }

    fn session_generation(&self) -> u64 {
        self.session.generation()
    }

    fn acknowledge_preview_ready(
        &mut self,
        helper_epoch: &str,
        session_generation: u64,
    ) -> Result<(), FailureReason> {
        if helper_epoch != self.helper_epoch {
            return Err(FailureReason::Disconnected);
        }
        self.session.acknowledge_preview_ready(session_generation)
    }

    fn reconnect_trusted_device(&mut self) -> Result<(), FailureReason> {
        let device = self
            .trusted_device
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?
            .clone()
            .ok_or(FailureReason::Disconnected)?;
        self.session.invalidate_and_wait();
        self.cancellation.cancel();
        self.pending = None;
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.cancellation = CancellationToken::new();
        self.pending_reconnect = Some(PendingReconnect { generation, device });
        Ok(())
    }

    fn stop_session(&mut self) {
        self.cancellation.cancel();
        self.pending_reconnect = None;
        self.pending = None;
        self.generation.fetch_add(1, Ordering::AcqRel);
        if let Ok(_flow) = self.flow.lock() {}

        self.session.invalidate_and_wait();
    }

    fn start_over(&mut self) -> Result<(), FailureReason> {
        let active_target = self.session.target()?;
        self.cancellation.cancel();

        let mut flow = self
            .flow
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        let mut trusted_device = self
            .trusted_device
            .lock()
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        // Start Over forgets the trusted device but intentionally retains global preferences.
        self.store
            .remove()
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        *trusted_device = None;

        self.session.invalidate_and_wait();
        self.pending = None;
        self.pending_reconnect = None;
        self.generation.fetch_add(1, Ordering::AcqRel);

        if let Some(target) = active_target {
            let cancellation = CancellationToken::new()
                .child_with_timeout(Duration::from_millis(MAX_LOCAL_COMMAND_MS));
            let _ = flow.runner_mut().run(
                CommandRequest::new("adb", vec!["disconnect".to_owned(), target]),
                &cancellation,
            );
        }
        drop(flow);
        drop(trusted_device);

        if let Ok(mut ceremony) = self.ceremony.lock() {
            ceremony.cancel();
        }
        Ok(())
    }

    fn pointer_tap(
        &mut self,
        geometry: DisplayGeometry,
        point: NormalizedPoint,
    ) -> Result<(), FailureReason> {
        self.run_input(MAX_LOCAL_COMMAND_MS, |adapter, target| {
            adapter.tap(target, geometry, point)
        })
    }

    fn pointer_swipe(
        &mut self,
        geometry: DisplayGeometry,
        start: NormalizedPoint,
        end: NormalizedPoint,
        duration_ms: u32,
    ) -> Result<(), FailureReason> {
        self.run_input(
            u64::from(duration_ms) + MAX_LOCAL_COMMAND_MS,
            |adapter, target| adapter.swipe(target, geometry, start, end, duration_ms),
        )
    }

    fn key_input(&mut self, key: AndroidKey) -> Result<(), FailureReason> {
        self.run_input(MAX_LOCAL_COMMAND_MS, |adapter, target| {
            adapter.key(target, key)
        })
    }

    fn text_input(&mut self, text: &str) -> Result<(), FailureReason> {
        let command_count = text.matches("%s").count() as u64 + 1;
        self.run_input(MAX_LOCAL_COMMAND_MS * command_count, |adapter, target| {
            adapter.text(target, text)
        })
    }

    fn phone_target(
        &mut self,
        target: PhoneTarget,
        _request_id: &str,
        expires_at_unix_ms: u64,
    ) -> Result<(), PhoneTargetFailure> {
        let remaining_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|duration| u64::try_from(duration.as_millis()).ok())
            .and_then(|now_unix_ms| expires_at_unix_ms.checked_sub(now_unix_ms))
            .filter(|remaining_ms| {
                *remaining_ms > 0 && *remaining_ms <= MAX_PHONE_TARGET_DEADLINE_AHEAD_MS
            })
            .ok_or(PhoneTargetFailure::ActionOnly(
                ActionFailureCode::InvalidDeadline,
            ))?;
        let selected_device = self
            .session
            .target()
            .map_err(PhoneTargetFailure::Lifecycle)?
            .ok_or(PhoneTargetFailure::ActionOnly(
                ActionFailureCode::TargetFailed,
            ))?;
        let session_cancellation = self.session.child_cancellation();
        let target_cancellation = session_cancellation.child_with_timeout(Duration::from_millis(
            remaining_ms.min(MAX_PHONE_TARGET_EXECUTION_MS),
        ));
        let result = {
            let mut flow = self
                .flow
                .lock()
                .map_err(|_| PhoneTargetFailure::ActionOnly(ActionFailureCode::TargetFailed))?;
            let mut adapter =
                AdbActionAdapter::new(flow.runner_mut().as_mut(), &target_cancellation);
            adapter.execute(&selected_device, &target)
        };
        match result {
            Ok(true) => Ok(()),
            Ok(false) | Err(ActionExecutionFailure::DependencyUnavailable) => Err(
                PhoneTargetFailure::ActionOnly(ActionFailureCode::TargetFailed),
            ),
            Err(ActionExecutionFailure::Cancelled)
                if target_cancellation.is_cancelled() && !session_cancellation.is_cancelled() =>
            {
                Err(PhoneTargetFailure::ActionOnly(
                    ActionFailureCode::TargetTimedOut,
                ))
            }
            Err(ActionExecutionFailure::Cancelled) => Err(PhoneTargetFailure::ActionOnly(
                ActionFailureCode::TargetFailed,
            )),
            Err(ActionExecutionFailure::Disconnected) => {
                self.session.invalidate_and_wait();
                Err(PhoneTargetFailure::Lifecycle(FailureReason::Disconnected))
            }
            Err(ActionExecutionFailure::Unauthorized) => {
                self.session.invalidate_and_wait();
                Err(PhoneTargetFailure::Lifecycle(FailureReason::Unauthorized))
            }
        }
    }

    fn preferences(&self) -> Preferences {
        self.preferences
    }

    fn scrcpy_configuration(&self) -> ScrcpyConfiguration {
        self.scrcpy_configuration.clone()
    }

    fn set_preferences(&mut self, preferences: Preferences) -> Result<bool, FailureReason> {
        let quality_changed = preferences.video_quality != self.preferences.video_quality;
        let restart_target = quality_changed
            .then(|| self.session.target())
            .transpose()?
            .flatten();

        self.preference_store
            .save(&preferences)
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        self.preferences = preferences;

        if let Some(target) = restart_target {
            self.session
                .restart(target, self.preferences.video_quality, self.sink.clone())?;
            return Ok(true);
        }
        Ok(false)
    }

    fn set_scrcpy_configuration(
        &mut self,
        configuration: ScrcpyConfiguration,
        screen_off_enabled: bool,
    ) -> Result<bool, FailureReason> {
        if screen_off_enabled && !configuration.screen_off_requested() {
            return Err(FailureReason::DependencyUnavailable);
        }
        let committed = self
            .scrcpy_config_store
            .load()
            .map_err(|_| FailureReason::DependencyUnavailable)?;
        if committed != configuration {
            return Err(FailureReason::DependencyUnavailable);
        }
        let changed = configuration != self.scrcpy_configuration
            || screen_off_enabled != self.effective_screen_off;
        let restart_target = changed
            .then(|| self.session.target())
            .transpose()?
            .flatten();
        if screen_off_enabled && restart_target.is_none() {
            return Err(FailureReason::Disconnected);
        }
        self.session
            .set_scrcpy_arguments(configuration.effective_arguments(screen_off_enabled))?;
        self.scrcpy_configuration = configuration;
        self.effective_screen_off = screen_off_enabled;
        if let Some(target) = restart_target {
            self.session
                .restart(target, self.preferences.video_quality, self.sink.clone())?;
            return Ok(true);
        }
        Ok(false)
    }

    fn response_emitted(&mut self) {
        self.launch_reconnect();
        self.launch_pending();
    }
}

#[must_use]
pub fn default_runtime_directory() -> Option<PathBuf> {
    env::var_os("XDG_RUNTIME_DIR")
        .filter(|directory| !directory.is_empty())
        .map(PathBuf::from)
        .map(|root| root.join("droid-peek"))
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::{FailureReason, SessionTransition};

    #[test]
    fn preview_acknowledgement_prevents_retry_claim_for_the_same_generation() {
        let transition = Mutex::new(SessionTransition::default());
        let mut transition = transition.lock().expect("session transition lock");

        let acknowledgement = transition.acknowledge_preview_ready(1, 1);
        let retry_generation = transition.claim_retry(1, 1, false);

        assert_eq!((acknowledgement, retry_generation), (Ok(()), None));
    }

    #[test]
    fn retry_claim_advances_generation_and_invalidates_late_acknowledgement() {
        let transition = Mutex::new(SessionTransition::default());
        let mut current_generation = 1;
        let retry_generation = transition
            .lock()
            .expect("session transition lock")
            .claim_retry(1, current_generation, false);
        current_generation = retry_generation.expect("retry generation");

        let acknowledgement = transition
            .lock()
            .expect("session transition lock")
            .acknowledge_preview_ready(1, current_generation);

        assert_eq!(
            (retry_generation, current_generation, acknowledgement),
            (Some(2), 2, Err(FailureReason::Disconnected))
        );
    }

    #[test]
    fn cancellation_prevents_retry_claim_for_the_current_generation() {
        let transition = Mutex::new(SessionTransition::default());
        let current_generation = 1;

        let retry_generation = transition
            .lock()
            .expect("session transition lock")
            .claim_retry(1, current_generation, true);

        assert_eq!((retry_generation, current_generation), (None, 1));
    }
}
