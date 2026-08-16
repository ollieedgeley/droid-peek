use std::{
    cell::RefCell,
    collections::VecDeque,
    convert::Infallible,
    path::{Path, PathBuf},
    rc::Rc,
    time::Duration,
};

use omarchy_android_helper::{
    process::{CommandFailure, CommandOutput, CommandRequest, CommandRunner},
    protocol::{Event, FailureReason, PROTOCOL_VERSION, PairingMethod},
    qr::{Clock, EntropySource, QrArtifact, QrCeremony, QrRenderer},
    wireless::{
        CancellationToken, DiscoveryFailure, PairingEndpoint, PairingFlow, WirelessDiscovery,
        pair_active_qr,
    },
};

struct FakeDiscovery {
    pairing: Result<PairingEndpoint, DiscoveryFailure>,
    connection: Result<PairingEndpoint, DiscoveryFailure>,
    requested_services: Vec<String>,
    connection_sources: Vec<PairingEndpoint>,
    cancel_after_pairing_discovery: bool,
}

impl WirelessDiscovery for FakeDiscovery {
    fn find_pairing_endpoint(
        &mut self,
        requested_service: &str,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        self.requested_services.push(requested_service.to_owned());
        if self.cancel_after_pairing_discovery {
            cancellation.cancel();
        }
        self.pairing.clone()
    }

    fn find_connection_endpoint(
        &mut self,
        pairing_endpoint: &PairingEndpoint,
        _cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
        self.connection_sources.push(pairing_endpoint.clone());
        self.connection.clone()
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

fn successful_flow() -> PairingFlow<FakeDiscovery, FakeRunner> {
    PairingFlow::new(
        FakeDiscovery {
            pairing: PairingEndpoint::new("pairing.local", 37_000)
                .map_err(|_| DiscoveryFailure::DependencyUnavailable),
            connection: PairingEndpoint::new("connect.local", 38_000)
                .map_err(|_| DiscoveryFailure::DependencyUnavailable),
            requested_services: Vec::new(),
            connection_sources: Vec::new(),
            cancel_after_pairing_discovery: false,
        },
        FakeRunner {
            outputs: VecDeque::from([
                Ok(CommandOutput { succeeded: true }),
                Ok(CommandOutput { succeeded: true }),
            ]),
            requests: Vec::new(),
        },
    )
}

#[test]
fn pairs_and_connects_only_the_requested_qr_service() {
    let mut flow = successful_flow();
    let cancellation = CancellationToken::new();
    let requested_service = "_adb-tls-pairing._tcp.requested";
    let secret = "temporary-qr-secret";

    let events = flow.pair(PairingMethod::Qr, requested_service, secret, &cancellation);

    assert_eq!(
        events,
        [
            format!(r#"{{"version":{PROTOCOL_VERSION},"type":"pairing","method":"qr"}}"#),
            format!(r#"{{"version":{PROTOCOL_VERSION},"type":"paired"}}"#),
        ]
    );
    assert!(events.iter().all(|event| !event.contains(secret)));
    assert!(events.iter().all(|event| !event.contains("pairing.local")));

    let (discovery, runner) = flow.into_parts();
    assert_eq!(discovery.requested_services, [requested_service]);
    assert_eq!(discovery.connection_sources.len(), 1);
    assert_eq!(runner.requests.len(), 2);
    assert_eq!(runner.requests[0].program(), "adb");
    assert_eq!(
        runner.requests[0].arguments(),
        ["pair", "pairing.local:37000", secret]
    );
    assert_eq!(runner.requests[1].program(), "adb");
    assert_eq!(
        runner.requests[1].arguments(),
        ["connect", "connect.local:38000"]
    );
}

#[test]
fn cancellation_stops_work_before_or_during_discovery() {
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let mut flow = successful_flow();

    assert_eq!(
        flow.pair(PairingMethod::Qr, "service", "secret", &cancellation),
        [Event::PairingCancelled.to_line()]
    );
    let (discovery, runner) = flow.into_parts();
    assert!(discovery.requested_services.is_empty());
    assert!(runner.requests.is_empty());

    let cancellation = CancellationToken::new();
    let mut flow = successful_flow();
    flow.discovery_mut().cancel_after_pairing_discovery = true;
    assert_eq!(
        flow.pair(PairingMethod::Qr, "service", "secret", &cancellation),
        [Event::PairingCancelled.to_line()]
    );
    let (_, runner) = flow.into_parts();
    assert!(runner.requests.is_empty());
}

#[test]
fn discovery_command_and_rejection_failures_are_redacted() {
    let cases = [
        (DiscoveryFailure::TimedOut, Event::QrTimedOut.to_line()),
        (
            DiscoveryFailure::NetworkUnavailable,
            Event::Failure {
                reason: FailureReason::NetworkUnavailable,
            }
            .to_line(),
        ),
        (
            DiscoveryFailure::DependencyUnavailable,
            Event::Failure {
                reason: FailureReason::DependencyUnavailable,
            }
            .to_line(),
        ),
    ];

    for (failure, expected) in cases {
        let mut flow = successful_flow();
        flow.discovery_mut().pairing = Err(failure);
        assert_eq!(
            flow.pair(
                PairingMethod::Qr,
                "requested-service",
                "secret",
                &CancellationToken::new(),
            ),
            [expected]
        );
    }

    let mut flow = successful_flow();
    flow.runner_mut().outputs = VecDeque::from([Err(CommandFailure::Unauthorized)]);
    assert_eq!(
        flow.pair(
            PairingMethod::Qr,
            "requested-service",
            "secret",
            &CancellationToken::new(),
        ),
        [
            Event::Pairing {
                method: PairingMethod::Qr,
            }
            .to_line(),
            Event::Failure {
                reason: FailureReason::Unauthorized,
            }
            .to_line(),
        ]
    );

    let mut flow = successful_flow();
    flow.runner_mut().outputs = VecDeque::from([Ok(CommandOutput { succeeded: false })]);
    assert_eq!(
        flow.pair(
            PairingMethod::Qr,
            "requested-service",
            "secret",
            &CancellationToken::new(),
        ),
        [
            Event::Pairing {
                method: PairingMethod::Qr,
            }
            .to_line(),
            Event::Failure {
                reason: FailureReason::PairingRejected,
            }
            .to_line(),
        ]
    );
}

#[test]
fn failed_tls_connection_is_a_disconnected_state() {
    let mut flow = successful_flow();
    flow.runner_mut().outputs = VecDeque::from([
        Ok(CommandOutput { succeeded: true }),
        Ok(CommandOutput { succeeded: false }),
    ]);

    assert_eq!(
        flow.pair(
            PairingMethod::ManualCode,
            "requested-service",
            "manual-code",
            &CancellationToken::new(),
        ),
        [
            Event::Pairing {
                method: PairingMethod::ManualCode,
            }
            .to_line(),
            Event::Failure {
                reason: FailureReason::Disconnected,
            }
            .to_line(),
        ]
    );
}

struct FixedEntropy(u8);

impl EntropySource for FixedEntropy {
    type Error = Infallible;

    fn fill(&mut self, bytes: &mut [u8]) -> Result<(), Self::Error> {
        for byte in bytes {
            *byte = self.0;
            self.0 = self.0.wrapping_add(1);
        }
        Ok(())
    }
}

struct FixedClock;

impl Clock for FixedClock {
    fn now(&self) -> Duration {
        Duration::ZERO
    }
}

struct MemoryArtifact(PathBuf);

impl QrArtifact for MemoryArtifact {
    fn path(&self) -> &Path {
        &self.0
    }
}

struct CapturingRenderer(Rc<RefCell<Vec<String>>>);

impl QrRenderer for CapturingRenderer {
    type Artifact = MemoryArtifact;
    type Error = Infallible;

    fn render(&mut self, payload: &str) -> Result<Self::Artifact, Self::Error> {
        self.0.borrow_mut().push(payload.to_owned());
        Ok(MemoryArtifact(PathBuf::from("/runtime/qr.svg")))
    }
}

#[test]
fn active_qr_material_drives_the_flow_then_is_discarded() {
    let payloads = Rc::new(RefCell::new(Vec::new()));
    let mut ceremony = QrCeremony::new(
        FixedEntropy(1),
        FixedClock,
        CapturingRenderer(Rc::clone(&payloads)),
        Duration::from_secs(120),
    );
    ceremony.start().expect("active QR ceremony");
    let mut flow = successful_flow();

    let events = pair_active_qr(&mut ceremony, &mut flow, &CancellationToken::new());

    assert_eq!(
        events,
        [
            Event::Pairing {
                method: PairingMethod::Qr,
            }
            .to_line(),
            Event::Paired.to_line(),
        ]
    );
    assert!(!ceremony.has_active_session());

    let payload = &payloads.borrow()[0];
    let (service, secret) = payload
        .strip_prefix("WIFI:T:ADB;S:")
        .and_then(|payload| payload.strip_suffix(";;"))
        .and_then(|payload| payload.split_once(";P:"))
        .expect("ADB QR payload fields");
    let (discovery, runner) = flow.into_parts();
    assert_eq!(discovery.requested_services, [service]);
    assert_eq!(runner.requests[0].arguments()[2], secret);
}
