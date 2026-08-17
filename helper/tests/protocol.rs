use std::io::Write;

use omarchy_android_helper::input::{AndroidKey, DisplayGeometry, NormalizedPoint};
use omarchy_android_helper::preferences::{
    PreviewScale, QuickAction, RenderPreferences, VideoQuality,
};
use omarchy_android_helper::protocol::{
    FailureReason, PROTOCOL_VERSION, PairingBackend, ProtocolEngine, QrPresentation,
};
use omarchy_android_helper::runtime::AcceptanceEventWriter;

#[derive(Default)]
struct FakePairingBackend {
    manual_codes: Vec<String>,
    reconnects: usize,
    session_stops: usize,
    pointer_taps: Vec<(DisplayGeometry, NormalizedPoint)>,
    pointer_swipes: Vec<(DisplayGeometry, NormalizedPoint, NormalizedPoint, u32)>,
    keys: Vec<AndroidKey>,
    texts: Vec<String>,
    preference_updates: Vec<RenderPreferences>,
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

    fn reconnect_trusted_device(&mut self) -> Result<(), FailureReason> {
        self.reconnects += 1;
        Ok(())
    }

    fn stop_session(&mut self) {
        self.session_stops += 1;
    }

    fn pointer_tap(
        &mut self,
        geometry: DisplayGeometry,
        point: NormalizedPoint,
    ) -> Result<(), FailureReason> {
        self.pointer_taps.push((geometry, point));
        Ok(())
    }

    fn pointer_swipe(
        &mut self,
        geometry: DisplayGeometry,
        start: NormalizedPoint,
        end: NormalizedPoint,
        duration_ms: u32,
    ) -> Result<(), FailureReason> {
        self.pointer_swipes
            .push((geometry, start, end, duration_ms));
        Ok(())
    }

    fn key_input(&mut self, key: AndroidKey) -> Result<(), FailureReason> {
        self.keys.push(key);
        Ok(())
    }

    fn text_input(&mut self, text: &str) -> Result<(), FailureReason> {
        self.texts.push(text.to_owned());
        Ok(())
    }

    fn render_preferences(&self) -> RenderPreferences {
        self.preference_updates.last().copied().unwrap_or_default()
    }

    fn set_render_preferences(
        &mut self,
        preferences: RenderPreferences,
    ) -> Result<bool, FailureReason> {
        let restarted = preferences.video_quality != self.render_preferences().video_quality;
        self.preference_updates.push(preferences);
        Ok(restarted)
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
fn reconnect_command_emits_redacted_progress_and_calls_backend() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    assert_eq!(
        engine.handle_line(r#"{"version":1,"type":"reconnect-trusted-device"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"connecting"}}"#
        )]
    );

    let backend = engine.into_backend();
    assert_eq!(backend.reconnects, 1);
}

#[test]
fn stop_session_confirms_cleanup_and_calls_backend() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    assert_eq!(
        engine.handle_line(r#"{"version":1,"type":"stop-session"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"session-stopped"}}"#
        )]
    );

    let backend = engine.into_backend();
    assert_eq!(backend.session_stops, 1);
}

#[test]
fn render_preferences_are_validated_forwarded_and_echoed() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    assert_eq!(
        engine.handle_line(
            r#"{"version":2,"type":"set-render-preferences","previewScale":150,"videoQuality":"low","quickActions":["home","recent-apps","back"]}"#,
        ),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"preferences-updated","previewScale":150,"videoQuality":"low","quickActions":["home","recent-apps","back"],"sessionRestarted":true}}"#
        )]
    );

    let backend = engine.into_backend();
    assert_eq!(
        backend.preference_updates,
        [RenderPreferences {
            preview_scale: PreviewScale::new(150).expect("valid preview scale"),
            video_quality: VideoQuality::Low,
            quick_actions: [
                QuickAction::Home,
                QuickAction::RecentApps,
                QuickAction::Back
            ],
        }]
    );
}

#[test]
fn invalid_render_preferences_do_not_reach_the_backend() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());
    let invalid = [
        r#"{"version":2,"type":"set-render-preferences","previewScale":49,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":2,"type":"set-render-preferences","previewScale":151,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":2,"type":"set-render-preferences","previewScale":100,"videoQuality":"ultra","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":2,"type":"set-render-preferences","previewScale":100,"videoQuality":"high","quickActions":["back"]}"#,
    ];

    for command in invalid {
        assert_eq!(
            engine.handle_line(command),
            [format!(
                r#"{{"version":{PROTOCOL_VERSION},"type":"protocol-error","reason":"invalid-command"}}"#
            )]
        );
    }
    assert!(engine.into_backend().preference_updates.is_empty());
}

#[test]
fn input_commands_are_versioned_validated_and_forwarded_without_response_noise() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    assert!(engine
        .handle_line(
            r#"{"version":1,"type":"pointer-tap","x":0.25,"y":0.75,"displayWidth":1080,"displayHeight":2400}"#,
        )
        .is_empty());
    assert!(engine
        .handle_line(
            r#"{"version":1,"type":"pointer-swipe","startX":0.1,"startY":0.2,"endX":0.8,"endY":0.9,"displayWidth":1080,"displayHeight":2400,"durationMs":320}"#,
        )
        .is_empty());
    assert!(
        engine
            .handle_line(r#"{"version":1,"type":"key-input","key":"back"}"#)
            .is_empty()
    );
    assert!(
        engine
            .handle_line(r#"{"version":1,"type":"text-input","text":"a"}"#)
            .is_empty()
    );

    let backend = engine.into_backend();
    assert_eq!(backend.pointer_taps.len(), 1);
    assert_eq!(backend.pointer_swipes.len(), 1);
    assert_eq!(backend.pointer_swipes[0].3, 320);
    assert_eq!(backend.keys, [AndroidKey::Back]);
    assert_eq!(backend.texts, ["a"]);
}

#[test]
fn malformed_input_is_rejected_before_reaching_the_backend() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());
    let invalid_commands = [
        r#"{"version":1,"type":"pointer-tap","x":1.01,"y":0.5,"displayWidth":1080,"displayHeight":2400}"#,
        r#"{"version":1,"type":"pointer-tap","x":0.5,"y":0.5,"displayWidth":0,"displayHeight":2400}"#,
        r#"{"version":1,"type":"pointer-swipe","startX":0.1,"startY":0.2,"endX":0.8,"endY":0.9,"displayWidth":1080,"displayHeight":2400,"durationMs":0}"#,
        r#"{"version":1,"type":"text-input","text":"line\nfeed"}"#,
    ];
    let expected = [format!(
        r#"{{"version":{PROTOCOL_VERSION},"type":"protocol-error","reason":"invalid-command"}}"#
    )];

    for command in invalid_commands {
        assert_eq!(engine.handle_line(command), expected);
    }

    let backend = engine.into_backend();
    assert!(backend.pointer_taps.is_empty());
    assert!(backend.pointer_swipes.is_empty());
    assert!(backend.texts.is_empty());
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
