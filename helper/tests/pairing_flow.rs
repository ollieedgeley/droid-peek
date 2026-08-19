use std::collections::VecDeque;

use droid_peek_helper::{
    persistence::TrustedDevice,
    process::{CommandFailure, CommandOutput, CommandRequest, CommandRunner},
    protocol::{FailureReason, PairingEvent as Event, PairingMethod},
    wireless::{
        CancellationToken, DiscoveryFailure, PairingEndpoint, PairingFlow, WirelessDiscovery,
    },
};

struct FakeDiscovery {
    pairing: Result<PairingEndpoint, DiscoveryFailure>,
    connection: Result<PairingEndpoint, DiscoveryFailure>,
    requested_services: Vec<String>,
    connection_sources: Vec<PairingEndpoint>,
    cancel_after_pairing_discovery: bool,
    paired_device: Option<TrustedDevice>,
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

    fn find_manual_pairing_endpoint(
        &mut self,
        cancellation: &CancellationToken,
    ) -> Result<PairingEndpoint, DiscoveryFailure> {
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

    fn take_paired_device(&mut self) -> Option<TrustedDevice> {
        self.paired_device.take()
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
            paired_device: Some(
                TrustedDevice::new("adb-associated-connect").expect("trusted device"),
            ),
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

fn collect_events(run: impl FnOnce(&mut dyn FnMut(Event))) -> Vec<Event> {
    let mut events = Vec::new();
    run(&mut |event| events.push(event));
    events
}

#[test]
fn pairs_and_connects_only_the_requested_qr_service() {
    let mut flow = successful_flow();
    let cancellation = CancellationToken::new();
    let requested_service = "_adb-tls-pairing._tcp.requested";
    let secret = "temporary-qr-secret";

    let events = collect_events(|emit| {
        flow.pair_with(
            PairingMethod::Qr,
            requested_service,
            secret,
            &cancellation,
            emit,
        );
    });

    assert!(matches!(
        events.as_slice(),
        [
            Event::Pairing {
                method: PairingMethod::Qr
            },
            Event::Paired
        ]
    ));
    assert_eq!(
        flow.take_connected_target().as_deref(),
        Some("connect.local:38000")
    );
    assert_eq!(
        flow.take_paired_device()
            .as_ref()
            .map(TrustedDevice::service_name),
        Some("adb-associated-connect")
    );

    let (discovery, runner) = flow.into_parts();
    assert_eq!(discovery.requested_services, [requested_service]);
    assert_eq!(discovery.connection_sources.len(), 1);
    assert_eq!(runner.requests.len(), 2);
    assert_eq!(runner.requests[0].program(), "adb");
    assert_eq!(
        runner.requests[0].arguments(),
        ["pair", "pairing.local:37000"]
    );
    assert_eq!(runner.requests[0].stdin(), Some("temporary-qr-secret\n"));
    assert_eq!(runner.requests[1].program(), "adb");
    assert_eq!(
        runner.requests[1].arguments(),
        ["connect", "connect.local:38000"]
    );
    assert_eq!(runner.requests[1].stdin(), None);
}

#[test]
fn cancellation_stops_work_before_or_during_discovery() {
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let mut flow = successful_flow();

    let events = collect_events(|emit| {
        flow.pair_with(PairingMethod::Qr, "service", "secret", &cancellation, emit);
    });
    assert!(matches!(events.as_slice(), [Event::PairingCancelled]));
    let (discovery, runner) = flow.into_parts();
    assert!(discovery.requested_services.is_empty());
    assert!(runner.requests.is_empty());

    let cancellation = CancellationToken::new();
    let mut flow = successful_flow();
    flow.discovery_mut().cancel_after_pairing_discovery = true;
    let events = collect_events(|emit| {
        flow.pair_with(PairingMethod::Qr, "service", "secret", &cancellation, emit);
    });
    assert!(matches!(events.as_slice(), [Event::PairingCancelled]));
    let (_, runner) = flow.into_parts();
    assert!(runner.requests.is_empty());
}

#[test]
fn discovery_command_and_rejection_failures_are_redacted() {
    enum ExpectedEvent {
        QrTimedOut,
        Failure(FailureReason),
    }

    let cases = [
        (DiscoveryFailure::TimedOut, ExpectedEvent::QrTimedOut),
        (
            DiscoveryFailure::NetworkUnavailable,
            ExpectedEvent::Failure(FailureReason::NetworkUnavailable),
        ),
        (
            DiscoveryFailure::DependencyUnavailable,
            ExpectedEvent::Failure(FailureReason::DependencyUnavailable),
        ),
    ];

    for (failure, expected) in cases {
        let mut flow = successful_flow();
        flow.discovery_mut().pairing = Err(failure);
        let events = collect_events(|emit| {
            flow.pair_with(
                PairingMethod::Qr,
                "requested-service",
                "secret",
                &CancellationToken::new(),
                emit,
            );
        });
        let matches_expected = match (events.as_slice(), expected) {
            ([Event::QrTimedOut], ExpectedEvent::QrTimedOut) => true,
            ([Event::Failure { reason }], ExpectedEvent::Failure(expected_reason)) => {
                *reason == expected_reason
            }
            _ => false,
        };
        assert!(matches_expected);
    }

    let mut flow = successful_flow();
    flow.runner_mut().outputs = VecDeque::from([Err(CommandFailure::Unauthorized)]);
    let events = collect_events(|emit| {
        flow.pair_with(
            PairingMethod::Qr,
            "requested-service",
            "secret",
            &CancellationToken::new(),
            emit,
        );
    });
    assert!(matches!(
        events.as_slice(),
        [
            Event::Pairing {
                method: PairingMethod::Qr
            },
            Event::Failure {
                reason: FailureReason::Unauthorized
            }
        ]
    ));

    let mut flow = successful_flow();
    flow.runner_mut().outputs = VecDeque::from([Ok(CommandOutput { succeeded: false })]);
    let events = collect_events(|emit| {
        flow.pair_with(
            PairingMethod::Qr,
            "requested-service",
            "secret",
            &CancellationToken::new(),
            emit,
        );
    });
    assert!(matches!(
        events.as_slice(),
        [
            Event::Pairing {
                method: PairingMethod::Qr
            },
            Event::Failure {
                reason: FailureReason::PairingRejected
            }
        ]
    ));
}

#[test]
fn failed_tls_connection_is_a_disconnected_state() {
    let mut flow = successful_flow();
    flow.runner_mut().outputs = VecDeque::from([
        Ok(CommandOutput { succeeded: true }),
        Ok(CommandOutput { succeeded: false }),
    ]);

    let events = collect_events(|emit| {
        flow.pair_manual_with("manual-code", &CancellationToken::new(), emit);
    });
    assert!(matches!(
        events.as_slice(),
        [Event::Failure {
            reason: FailureReason::Disconnected
        }]
    ));
}
