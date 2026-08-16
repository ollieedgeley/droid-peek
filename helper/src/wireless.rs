//! Wireless-debugging discovery and pairing orchestration contracts.

use std::{
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::mpsc::{self, RecvTimeoutError},
    thread,
    time::{Duration, Instant},
};

pub use crate::process::CancellationToken;

use crate::{
    persistence::TrustedDevice,
    process::{CommandFailure, CommandRequest, CommandRunner},
    protocol::{Event, FailureReason, PairingMethod},
    qr::{Clock, EntropySource, QrCeremony, QrRenderer},
};

/// A local endpoint discovered for an Android Wireless debugging service.
///
/// It deliberately has no `Debug` implementation so endpoints cannot be
/// included in diagnostic output by accident.
#[derive(Clone, Eq, PartialEq)]
pub struct PairingEndpoint {
    host: String,
    port: u16,
}

impl PairingEndpoint {
    pub fn new(host: impl Into<String>, port: u16) -> Result<Self, EndpointError> {
        let host = host.into();
        if host.trim().is_empty() {
            return Err(EndpointError::EmptyHost);
        }
        if port == 0 {
            return Err(EndpointError::ZeroPort);
        }

        Ok(Self { host, port })
    }

    fn adb_target(&self) -> String {
        if self.host.contains(':') && !self.host.starts_with('[') {
            format!("[{}]:{}", self.host, self.port)
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum EndpointError {
    EmptyHost,
    ZeroPort,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiscoveryFailure {
    DependencyUnavailable,
    NetworkUnavailable,
    TimedOut,
    Cancelled,
}

/// Discovers the requested temporary pairing service and its associated TLS
/// connection service. Implementations must observe cancellation while waiting.
pub trait WirelessDiscovery {
    fn find_pairing_endpoint(
        &mut self,
        requested_service: &str,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure>;

    fn find_manual_pairing_endpoint(
        &mut self,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        Err(DiscoveryFailure::DependencyUnavailable)
    }

    fn find_connection_endpoint(
        &mut self,
        pairing_endpoint: &PairingEndpoint,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure>;

    fn find_trusted_connection(
        &mut self,
        _device: &TrustedDevice,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        Err(DiscoveryFailure::DependencyUnavailable)
    }

    fn take_paired_device(&mut self) -> Option<TrustedDevice> {
        None
    }
}

impl<T> WirelessDiscovery for Box<T>
where
    T: WirelessDiscovery + ?Sized,
{
    fn find_pairing_endpoint(
        &mut self,
        requested_service: &str,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        (**self).find_pairing_endpoint(requested_service, cancellation)
    }

    fn find_manual_pairing_endpoint(
        &mut self,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        (**self).find_manual_pairing_endpoint(cancellation)
    }

    fn find_connection_endpoint(
        &mut self,
        pairing_endpoint: &PairingEndpoint,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        (**self).find_connection_endpoint(pairing_endpoint, cancellation)
    }

    fn find_trusted_connection(
        &mut self,
        device: &TrustedDevice,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        (**self).find_trusted_connection(device, cancellation)
    }

    fn take_paired_device(&mut self) -> Option<TrustedDevice> {
        (**self).take_paired_device()
    }
}

const PAIRING_SERVICE_TYPE: &str = "_adb-tls-pairing._tcp";
const CONNECTION_SERVICE_TYPE: &str = "_adb-tls-connect._tcp";
const MANUAL_DISCOVERY_SETTLE_TIME: Duration = Duration::from_millis(250);

/// Discovers Android Wireless debugging services through Avahi's parsable
/// resolved-service stream.
pub struct AvahiDiscovery {
    executable: PathBuf,
    timeout: Duration,
    poll_interval: Duration,
    paired_device: Option<TrustedDevice>,
}

impl AvahiDiscovery {
    #[must_use]
    pub fn new(executable: impl AsRef<Path>, timeout: Duration, poll_interval: Duration) -> Self {
        Self {
            executable: executable.as_ref().to_owned(),
            timeout,
            poll_interval,
            paired_device: None,
        }
    }

    fn browse<F>(
        &self,
        service_type: &str,
        cancellation: &CancellationToken,
        require_unique_match: bool,
        matches: F,
    ) -> Result<ResolvedService, DiscoveryFailure>
    where
        F: Fn(&ResolvedService) -> bool,
    {
        if cancellation.is_cancelled() {
            return Err(DiscoveryFailure::Cancelled);
        }

        let mut child = Command::new(&self.executable)
            .args(["--parsable", "--resolve", service_type])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| DiscoveryFailure::DependencyUnavailable)?;
        let stdout = child
            .stdout
            .take()
            .ok_or(DiscoveryFailure::DependencyUnavailable)?;
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if sender.send(line).is_err() {
                    break;
                }
            }
        });

        let deadline = Instant::now() + self.timeout;
        let mut candidate = None;
        let mut settle_deadline = None;
        loop {
            if cancellation.is_cancelled() {
                stop_child(&mut child);
                return Err(DiscoveryFailure::Cancelled);
            }

            let now = Instant::now();
            if settle_deadline.is_some_and(|settle| now >= settle) {
                stop_child(&mut child);
                return candidate.ok_or(DiscoveryFailure::NetworkUnavailable);
            }
            if now >= deadline {
                stop_child(&mut child);
                return candidate.ok_or(DiscoveryFailure::TimedOut);
            }
            let active_deadline = settle_deadline.unwrap_or(deadline).min(deadline);
            let wait = self
                .poll_interval
                .min(active_deadline.saturating_duration_since(now));
            match receiver.recv_timeout(wait) {
                Ok(Ok(line)) => {
                    if let Some(service) = ResolvedService::parse(&line)
                        && service.service_type == service_type
                        && matches(&service)
                    {
                        PairingEndpoint::new(&service.address, service.port)
                            .map_err(|_| DiscoveryFailure::NetworkUnavailable)?;
                        if !require_unique_match {
                            stop_child(&mut child);
                            return Ok(service);
                        }
                        if candidate.as_ref().is_some_and(|current: &ResolvedService| {
                            current.address != service.address || current.port != service.port
                        }) {
                            stop_child(&mut child);
                            return Err(DiscoveryFailure::NetworkUnavailable);
                        }
                        candidate = Some(service);
                        settle_deadline = Some(Instant::now() + MANUAL_DISCOVERY_SETTLE_TIME);
                    }
                }
                Ok(Err(_)) => {}
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    stop_child(&mut child);
                    return candidate.ok_or(DiscoveryFailure::NetworkUnavailable);
                }
            }

            match child.try_wait() {
                Ok(Some(_)) => {
                    return candidate.ok_or(DiscoveryFailure::NetworkUnavailable);
                }
                Ok(None) => {}
                Err(_) => {
                    stop_child(&mut child);
                    return Err(DiscoveryFailure::NetworkUnavailable);
                }
            }
        }
    }
}

impl WirelessDiscovery for AvahiDiscovery {
    fn find_pairing_endpoint(
        &mut self,
        requested_service: &str,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        self.browse(PAIRING_SERVICE_TYPE, cancellation, false, |service| {
            service.name == requested_service
        })
        .and_then(service_endpoint)
    }

    fn find_manual_pairing_endpoint(
        &mut self,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        self.browse(PAIRING_SERVICE_TYPE, cancellation, true, |_| true)
            .and_then(service_endpoint)
    }

    fn find_connection_endpoint(
        &mut self,
        pairing_endpoint: &PairingEndpoint,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        let service = self.browse(CONNECTION_SERVICE_TYPE, cancellation, false, |service| {
            service.address == pairing_endpoint.host
        })?;
        let device =
            TrustedDevice::new(&service.name).map_err(|_| DiscoveryFailure::NetworkUnavailable)?;
        let endpoint = service_endpoint(service)?;
        self.paired_device = Some(device);
        Ok(endpoint)
    }

    fn find_trusted_connection(
        &mut self,
        device: &TrustedDevice,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        self.browse(CONNECTION_SERVICE_TYPE, cancellation, false, |service| {
            service.name == device.service_name()
        })
        .and_then(service_endpoint)
    }

    fn take_paired_device(&mut self) -> Option<TrustedDevice> {
        self.paired_device.take()
    }
}

struct ResolvedService {
    name: String,
    service_type: String,
    address: String,
    port: u16,
}

impl ResolvedService {
    fn parse(line: &str) -> Option<Self> {
        let fields = line.split(';').collect::<Vec<_>>();
        if fields.len() < 9 || fields[0] != "=" {
            return None;
        }
        Some(Self {
            name: unescape_avahi(fields[3])?,
            service_type: unescape_avahi(fields[4])?,
            address: unescape_avahi(fields[7])?,
            port: fields[8].parse().ok()?,
        })
    }
}

fn service_endpoint(service: ResolvedService) -> Result<PairingEndpoint, DiscoveryFailure> {
    PairingEndpoint::new(service.address, service.port)
        .map_err(|_| DiscoveryFailure::NetworkUnavailable)
}

fn unescape_avahi(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = String::with_capacity(value.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\\' {
            if index + 3 >= bytes.len()
                || !bytes[index + 1..=index + 3].iter().all(u8::is_ascii_digit)
            {
                return None;
            }
            let escaped = (bytes[index + 1] - b'0') * 100
                + (bytes[index + 2] - b'0') * 10
                + (bytes[index + 3] - b'0');
            decoded.push(char::from(escaped));
            index += 4;
        } else {
            let character = value[index..].chars().next()?;
            decoded.push(character);
            index += character.len_utf8();
        }
    }
    Some(decoded)
}

fn stop_child(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Coordinates discovery, `adb pair`, TLS service discovery, and `adb connect`
/// without depending on a concrete mDNS or process implementation.
pub struct PairingFlow<D, R> {
    discovery: D,
    runner: R,
    paired_device: Option<TrustedDevice>,
    connected_target: Option<String>,
}

impl<D, R> PairingFlow<D, R> {
    #[must_use]
    pub fn new(discovery: D, runner: R) -> Self {
        Self {
            discovery,
            runner,
            paired_device: None,
            connected_target: None,
        }
    }

    #[must_use]
    pub fn into_parts(self) -> (D, R) {
        (self.discovery, self.runner)
    }

    pub fn discovery_mut(&mut self) -> &mut D {
        &mut self.discovery
    }

    pub fn runner_mut(&mut self) -> &mut R {
        &mut self.runner
    }

    pub fn take_paired_device(&mut self) -> Option<TrustedDevice> {
        self.paired_device.take()
    }

    pub fn take_connected_target(&mut self) -> Option<String> {
        self.connected_target.take()
    }
}

impl<D, R> PairingFlow<D, R>
where
    D: WirelessDiscovery,
    R: CommandRunner,
{
    #[must_use]
    pub fn pair(
        &mut self,
        method: PairingMethod,
        requested_service: &str,
        pairing_code: &str,
        cancellation: &CancellationToken,
    ) -> Vec<String> {
        self.paired_device = None;
        self.connected_target = None;
        let mut events = Vec::new();
        self.pair_with(
            method,
            requested_service,
            pairing_code,
            cancellation,
            |event| events.push(event.to_line()),
        );
        events
    }

    pub fn pair_with(
        &mut self,
        method: PairingMethod,
        requested_service: &str,
        pairing_code: &str,
        cancellation: &CancellationToken,
        mut emit: impl FnMut(Event),
    ) {
        self.paired_device = None;
        self.connected_target = None;
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
            return;
        }

        let pairing_endpoint = match self
            .discovery
            .find_pairing_endpoint(requested_service, cancellation)
        {
            Ok(endpoint) => endpoint,
            Err(failure) => {
                emit(pairing_discovery_failure(failure, method));
                return;
            }
        };
        self.complete_pairing_with(
            method,
            pairing_endpoint,
            pairing_code,
            cancellation,
            true,
            emit,
        );
    }

    pub fn pair_manual_with(
        &mut self,
        pairing_code: &str,
        cancellation: &CancellationToken,
        mut emit: impl FnMut(Event),
    ) {
        self.connected_target = None;
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
            return;
        }

        let pairing_endpoint = match self.discovery.find_manual_pairing_endpoint(cancellation) {
            Ok(endpoint) => endpoint,
            Err(failure) => {
                emit(pairing_discovery_failure(
                    failure,
                    PairingMethod::ManualCode,
                ));
                return;
            }
        };
        self.complete_pairing_with(
            PairingMethod::ManualCode,
            pairing_endpoint,
            pairing_code,
            cancellation,
            false,
            emit,
        );
    }

    #[must_use]
    pub fn reconnect(
        &mut self,
        device: &TrustedDevice,
        cancellation: &CancellationToken,
    ) -> Vec<String> {
        let mut events = Vec::new();
        self.reconnect_with(device, cancellation, |event| events.push(event.to_line()));
        events
    }

    pub fn reconnect_with(
        &mut self,
        device: &TrustedDevice,
        cancellation: &CancellationToken,
        mut emit: impl FnMut(Event),
    ) {
        self.connected_target = None;
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
            return;
        }
        let endpoint = match self.discovery.find_trusted_connection(device, cancellation) {
            Ok(endpoint) => endpoint,
            Err(failure) => {
                emit(connection_discovery_failure(failure));
                return;
            }
        };
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
            return;
        }
        let output = match self
            .runner
            .run(adb_connect_request(&endpoint), cancellation)
        {
            Ok(output) => output,
            Err(failure) => {
                emit(command_failure(failure));
                return;
            }
        };
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
        } else if output.succeeded {
            self.connected_target = Some(endpoint.adb_target());
            emit(Event::Connected);
        } else {
            emit(Event::Failure {
                reason: FailureReason::Disconnected,
            });
        }
    }

    fn complete_pairing_with(
        &mut self,
        method: PairingMethod,
        pairing_endpoint: PairingEndpoint,
        pairing_code: &str,
        cancellation: &CancellationToken,
        emit_progress: bool,
        mut emit: impl FnMut(Event),
    ) {
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
            return;
        }
        if emit_progress {
            emit(Event::Pairing { method });
        }

        let pair_output = match self.runner.run(
            adb_pair_request(&pairing_endpoint, pairing_code),
            cancellation,
        ) {
            Ok(output) => output,
            Err(failure) => {
                emit(command_failure(failure));
                return;
            }
        };
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
            return;
        }
        if !pair_output.succeeded {
            emit(Event::Failure {
                reason: FailureReason::PairingRejected,
            });
            return;
        }

        let connection_endpoint = match self
            .discovery
            .find_connection_endpoint(&pairing_endpoint, cancellation)
        {
            Ok(endpoint) => endpoint,
            Err(failure) => {
                emit(connection_discovery_failure(failure));
                return;
            }
        };
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
            return;
        }

        let connect_output = match self
            .runner
            .run(adb_connect_request(&connection_endpoint), cancellation)
        {
            Ok(output) => output,
            Err(failure) => {
                emit(command_failure(failure));
                return;
            }
        };
        if cancellation.is_cancelled() {
            emit(Event::PairingCancelled);
            return;
        }
        if !connect_output.succeeded {
            emit(Event::Failure {
                reason: FailureReason::Disconnected,
            });
            return;
        }

        self.connected_target = Some(connection_endpoint.adb_target());
        self.paired_device = self.discovery.take_paired_device();
        emit(Event::Paired);
    }
}

pub fn pair_active_qr<E, C, Q, D, R>(
    ceremony: &mut QrCeremony<E, C, Q>,
    flow: &mut PairingFlow<D, R>,
    cancellation: &CancellationToken,
) -> Vec<String>
where
    E: EntropySource,
    C: Clock,
    Q: QrRenderer,
    D: WirelessDiscovery,
    R: CommandRunner,
{
    let events = ceremony.with_pairing_material(|requested_service, secret| {
        flow.pair(PairingMethod::Qr, requested_service, secret, cancellation)
    });
    ceremony.cancel();
    events.unwrap_or_else(|| vec![Event::QrTimedOut.to_line()])
}

fn pairing_discovery_failure(failure: DiscoveryFailure, method: PairingMethod) -> Event {
    match failure {
        DiscoveryFailure::TimedOut if method == PairingMethod::Qr => Event::QrTimedOut,
        DiscoveryFailure::TimedOut => Event::Failure {
            reason: FailureReason::NetworkUnavailable,
        },
        DiscoveryFailure::DependencyUnavailable => Event::Failure {
            reason: FailureReason::DependencyUnavailable,
        },
        DiscoveryFailure::NetworkUnavailable => Event::Failure {
            reason: FailureReason::NetworkUnavailable,
        },
        DiscoveryFailure::Cancelled => Event::PairingCancelled,
    }
}

fn connection_discovery_failure(failure: DiscoveryFailure) -> Event {
    match failure {
        DiscoveryFailure::DependencyUnavailable => Event::Failure {
            reason: FailureReason::DependencyUnavailable,
        },
        DiscoveryFailure::NetworkUnavailable | DiscoveryFailure::TimedOut => Event::Failure {
            reason: FailureReason::Disconnected,
        },
        DiscoveryFailure::Cancelled => Event::PairingCancelled,
    }
}

fn command_failure(failure: CommandFailure) -> Event {
    match failure {
        CommandFailure::DependencyUnavailable => Event::Failure {
            reason: FailureReason::DependencyUnavailable,
        },
        CommandFailure::Unauthorized => Event::Failure {
            reason: FailureReason::Unauthorized,
        },
        CommandFailure::Cancelled => Event::PairingCancelled,
    }
}

fn adb_pair_request(endpoint: &PairingEndpoint, pairing_code: &str) -> CommandRequest {
    CommandRequest::new(
        "adb",
        vec![
            "pair".to_owned(),
            endpoint.adb_target(),
            pairing_code.to_owned(),
        ],
    )
}

fn adb_connect_request(endpoint: &PairingEndpoint) -> CommandRequest {
    CommandRequest::new("adb", vec!["connect".to_owned(), endpoint.adb_target()])
}
