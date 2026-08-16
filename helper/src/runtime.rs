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
    process::{AdbCommandRunner, CancellationToken, CommandRunner},
    protocol::{Event, FailureReason, PairingBackend, PairingMethod, QrPresentation},
    qr::{QrCeremony, RuntimeQrRenderer, SystemClock, SystemEntropy},
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

pub struct RuntimePairingBackend<S> {
    ceremony: Arc<Mutex<RuntimeCeremony>>,
    flow: Arc<Mutex<RuntimeFlow>>,
    lifetime: Duration,
    sink: S,
    generation: Arc<AtomicU64>,
    cancellation: CancellationToken,
    pending: Option<PendingPairing>,
}

impl<S> RuntimePairingBackend<S>
where
    S: ProtocolSink,
{
    pub fn new(
        runtime_directory: impl AsRef<Path>,
        lifetime: Duration,
        sink: S,
    ) -> io::Result<Self> {
        Self::with_adapters(
            runtime_directory,
            lifetime,
            sink,
            AvahiDiscovery::new("avahi-browse", lifetime, Duration::from_millis(25)),
            AdbCommandRunner::new("adb", Duration::from_millis(25)),
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
        let ceremony = QrCeremony::new(
            SystemEntropy::new()?,
            SystemClock::new(),
            RuntimeQrRenderer::new(runtime_directory.as_ref()),
            lifetime,
        );
        Ok(Self {
            ceremony: Arc::new(Mutex::new(ceremony)),
            flow: Arc::new(Mutex::new(PairingFlow::new(
                Box::new(discovery),
                Box::new(runner),
            ))),
            lifetime,
            sink,
            generation: Arc::new(AtomicU64::new(0)),
            cancellation: CancellationToken::new(),
            pending: None,
        })
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
        let worker_cancellation = cancellation.clone();
        thread::spawn(move || {
            let mut terminal_event = None;
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
                if let Some(event) = terminal_event {
                    let _ = sink.emit_event(&event);
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
}

impl<S> PairingBackend for RuntimePairingBackend<S>
where
    S: ProtocolSink,
{
    fn start_qr_pairing(&mut self) -> Result<QrPresentation, FailureReason> {
        self.cancellation.cancel();
        self.pending = None;
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
        self.pending = None;
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
        self.cancellation.cancel();
        self.pending = None;
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

    fn response_emitted(&mut self) {
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
