use std::io::Write;

use omarchy_android_helper::protocol::{
    FailureReason, PROTOCOL_VERSION, PairingBackend, ProtocolEngine, QrPresentation,
};
use omarchy_android_helper::runtime::AcceptanceEventWriter;

#[derive(Default)]
struct FakePairingBackend {
    manual_codes: Vec<String>,
}

impl PairingBackend for FakePairingBackend {
    fn start_qr_pairing(&mut self) -> Result<QrPresentation, FailureReason> {
        Ok(QrPresentation {
            artifact: "/run/user/1000/omarchy-android/qr.svg".into(),
            expires_in_seconds: 120,
        })
    }

    fn cancel_pairing(&mut self) {}

    fn submit_manual_code(&mut self, code: &str) -> Result<(), FailureReason> {
        self.manual_codes.push(code.to_owned());
        Ok(())
    }
}

#[test]
fn qr_pairing_commands_emit_versioned_redacted_states() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    assert_eq!(
        engine.handle_line(r#"{"version":1,"type":"start-qr-pairing"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"qr-waiting","artifact":"/run/user/1000/omarchy-android/qr.svg","expiresInSeconds":120}}"#
        )]
    );
    assert_eq!(
        engine.handle_line(r#"{"version":1,"type":"cancel-pairing"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"pairing-cancelled"}}"#
        )]
    );
}

#[test]
fn manual_code_is_consumed_without_appearing_in_events() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());
    let code = "482913";

    assert_eq!(
        engine.handle_line(r#"{"version":1,"type":"use-manual-code"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"manual-code-required"}}"#
        )]
    );
    let events = engine.handle_line(&format!(
        r#"{{"version":1,"type":"submit-manual-code","code":"{code}"}}"#
    ));

    assert_eq!(
        events,
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"pairing","method":"manual-code"}}"#
        )]
    );
    assert!(events.iter().all(|event| !event.contains(code)));
    let mut writer = AcceptanceEventWriter::with_log(Vec::new(), Vec::new());
    for event in &events {
        writeln!(writer, "{event}").expect("write acceptance event");
    }
    let (_, log) = writer.into_parts();
    let log = String::from_utf8(log.expect("acceptance log")).expect("UTF-8 acceptance log");
    assert!(!log.contains(code));

    let backend = engine.into_backend();
    assert_eq!(backend.manual_codes, [code]);
}

#[test]
fn malformed_unknown_and_mismatched_commands_fail_without_echoing_input() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());
    let secret = "do-not-echo";

    let malformed = engine.handle_line(&format!(r#"{{"secret":"{secret}"}}"#));
    let unknown = engine.handle_line(r#"{"version":1,"type":"unknown"}"#);
    let mismatched = engine.handle_line(r#"{"version":9,"type":"start-qr-pairing"}"#);

    assert_eq!(
        malformed,
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"protocol-error","reason":"invalid-command"}}"#
        )]
    );
    assert_eq!(unknown, malformed);
    assert_eq!(
        mismatched,
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"protocol-error","reason":"version-mismatch"}}"#
        )]
    );
    assert!(malformed.iter().all(|event| !event.contains(secret)));
}

#[test]
fn backend_failures_are_fixed_categories_not_raw_messages() {
    struct UnavailableBackend;

    impl PairingBackend for UnavailableBackend {
        fn start_qr_pairing(&mut self) -> Result<QrPresentation, FailureReason> {
            Err(FailureReason::DependencyUnavailable)
        }

        fn cancel_pairing(&mut self) {}

        fn submit_manual_code(&mut self, _code: &str) -> Result<(), FailureReason> {
            Err(FailureReason::Unauthorized)
        }
    }

    let mut engine = ProtocolEngine::new(UnavailableBackend);

    assert_eq!(
        engine.handle_line(r#"{"version":1,"type":"start-qr-pairing"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"failure","reason":"dependency-unavailable"}}"#
        )]
    );
}
