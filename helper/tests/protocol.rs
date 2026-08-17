use std::io::Write;

use omarchy_android_helper::actions::SemanticAction;
use omarchy_android_helper::input::{AndroidKey, DisplayGeometry, NormalizedPoint};
use omarchy_android_helper::preferences::{Preferences, PreviewScale, QuickAction, VideoQuality};
use omarchy_android_helper::protocol::{
    Event, FailureReason, PROTOCOL_VERSION, PairingBackend, ProtocolEngine, QrPresentation,
};
use omarchy_android_helper::runtime::AcceptanceEventWriter;

#[derive(Default)]
struct FakePairingBackend {
    manual_codes: Vec<String>,
    reconnects: usize,
    session_stops: usize,
    start_overs: usize,
    pointer_taps: Vec<(DisplayGeometry, NormalizedPoint)>,
    pointer_swipes: Vec<(DisplayGeometry, NormalizedPoint, NormalizedPoint, u32)>,
    keys: Vec<AndroidKey>,
    texts: Vec<String>,
    semantic_actions: Vec<SemanticAction>,
    semantic_request_ids: Vec<String>,
    semantic_expires_at_unix_ms: Vec<u64>,
    semantic_action_arguments: Vec<Option<String>>,
    preference_updates: Vec<Preferences>,
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

    fn start_over(&mut self) -> Result<(), FailureReason> {
        self.start_overs += 1;
        Ok(())
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

    fn semantic_action(
        &mut self,
        action: SemanticAction,
        action_argument: Option<&str>,
        request_id: &str,
        expires_at_unix_ms: u64,
    ) -> Result<bool, FailureReason> {
        self.semantic_actions.push(action);
        self.semantic_action_arguments
            .push(action_argument.map(str::to_owned));
        self.semantic_request_ids.push(request_id.to_owned());
        self.semantic_expires_at_unix_ms.push(expires_at_unix_ms);
        Ok(matches!(
            action,
            SemanticAction::OmarchyBrowser
                | SemanticAction::OmarchyCloseCurrentWindow
                | SemanticAction::AndroidLaunchApp
        ))
    }

    fn text_input(&mut self, text: &str) -> Result<(), FailureReason> {
        self.texts.push(text.to_owned());
        Ok(())
    }

    fn preferences(&self) -> Preferences {
        self.preference_updates.last().copied().unwrap_or_default()
    }

    fn set_preferences(&mut self, preferences: Preferences) -> Result<bool, FailureReason> {
        let restarted = preferences.video_quality != self.preferences().video_quality;
        self.preference_updates.push(preferences);
        Ok(restarted)
    }
}

#[test]
fn protocol_version_nine_ready_event_exposes_android_mode_shortcuts() {
    assert_eq!(PROTOCOL_VERSION, 9);
    assert_eq!(
        Event::Ready {
            has_trusted_device: true,
            preferences: Preferences {
                keep_connected: true,
                android_mode_shortcuts: true,
                preview_scale: PreviewScale::new(125).expect("valid preview scale"),
                video_quality: VideoQuality::Low,
                quick_actions: [
                    QuickAction::Home,
                    QuickAction::RecentApps,
                    QuickAction::Back,
                ],
            },
        }
        .to_line(),
        r#"{"version":9,"type":"ready","hasTrustedDevice":true,"preferences":{"keepConnected":true,"androidModeShortcuts":true,"previewScale":125,"videoQuality":"low","quickActions":["home","recent-apps","back"]}}"#
    );
}

#[test]
fn qr_pairing_commands_emit_versioned_redacted_states() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    assert_eq!(
        engine.handle_line(r#"{"version":9,"type":"start-qr-pairing"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"qr-waiting","artifact":"/run/user/1000/omarchy-android/qr.svg","expiresInSeconds":120}}"#
        )]
    );
    assert_eq!(
        engine.handle_line(r#"{"version":9,"type":"cancel-pairing"}"#),
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
        engine.handle_line(r#"{"version":9,"type":"use-manual-code"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"manual-code-required"}}"#
        )]
    );
    let events = engine.handle_line(&format!(
        r#"{{"version":9,"type":"submit-manual-code","code":"{code}"}}"#
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
        engine.handle_line(r#"{"version":9,"type":"reconnect-trusted-device"}"#),
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
        engine.handle_line(r#"{"version":9,"type":"stop-session"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"session-stopped"}}"#
        )]
    );

    let backend = engine.into_backend();
    assert_eq!(backend.session_stops, 1);
}

#[test]
fn start_over_confirms_local_forgetting_and_calls_backend() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    assert_eq!(
        engine.handle_line(r#"{"version":9,"type":"start-over"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"start-over-complete"}}"#
        )]
    );

    let backend = engine.into_backend();
    assert_eq!(backend.start_overs, 1);
}

#[test]
fn preferences_are_validated_forwarded_and_echoed() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    assert_eq!(
        engine.handle_line(
            r#"{"version":9,"type":"set-preferences","keepConnected":true,"androidModeShortcuts":true,"previewScale":150,"videoQuality":"low","quickActions":["home","recent-apps","back"]}"#,
        ),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"preferences-updated","keepConnected":true,"androidModeShortcuts":true,"previewScale":150,"videoQuality":"low","quickActions":["home","recent-apps","back"],"sessionRestarted":true}}"#
        )]
    );

    let backend = engine.into_backend();
    assert_eq!(
        backend.preference_updates,
        [Preferences {
            keep_connected: true,
            android_mode_shortcuts: true,
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
fn invalid_preferences_do_not_reach_the_backend() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());
    let invalid = [
        r#"{"version":9,"type":"set-preferences","androidModeShortcuts":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":9,"type":"set-preferences","keepConnected":"yes","androidModeShortcuts":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":9,"type":"set-preferences","keepConnected":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":9,"type":"set-preferences","keepConnected":false,"androidModeShortcuts":"yes","previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":9,"type":"set-preferences","keepConnected":false,"androidModeShortcuts":false,"previewScale":49,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":9,"type":"set-preferences","keepConnected":false,"androidModeShortcuts":false,"previewScale":151,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":9,"type":"set-preferences","keepConnected":false,"androidModeShortcuts":false,"previewScale":100,"videoQuality":"ultra","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":9,"type":"set-preferences","keepConnected":false,"androidModeShortcuts":false,"previewScale":100,"videoQuality":"high","quickActions":["back"]}"#,
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
            r#"{"version":9,"type":"pointer-tap","x":0.25,"y":0.75,"displayWidth":1080,"displayHeight":2400}"#,
        )
        .is_empty());
    assert!(engine
        .handle_line(
            r#"{"version":9,"type":"pointer-swipe","startX":0.1,"startY":0.2,"endX":0.8,"endY":0.9,"displayWidth":1080,"displayHeight":2400,"durationMs":320}"#,
        )
        .is_empty());
    assert!(
        engine
            .handle_line(r#"{"version":9,"type":"key-input","key":"back"}"#)
            .is_empty()
    );
    assert!(
        engine
            .handle_line(r#"{"version":9,"type":"text-input","text":"a"}"#)
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
fn semantic_actions_emit_correlated_handled_results() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());

    for (action_id, request_id, expires_at_unix_ms, handled) in [
        ("omarchy-browser", "request-1", 1_750_000_000_001_u64, true),
        (
            "omarchy-close-current-window",
            "request-2",
            1_750_000_000_002,
            true,
        ),
        ("omarchy-menu", "request-3", 1_750_000_000_003, false),
    ] {
        assert_eq!(
            engine.handle_line(&format!(
                r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"{action_id}","requestId":"{request_id}","expiresAtUnixMs":{expires_at_unix_ms}}}"#
            )),
            [format!(
                r#"{{"version":{PROTOCOL_VERSION},"type":"action-result","actionId":"{action_id}","requestId":"{request_id}","handled":{handled}}}"#
            )]
        );
    }

    assert_eq!(
        engine.handle_line(&format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"android-launch-app","actionArgument":"com.example.notes","requestId":"request-package","expiresAtUnixMs":1750000000004}}"#
        )),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"action-result","actionId":"android-launch-app","requestId":"request-package","handled":true}}"#
        )]
    );

    for command in [
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"not-declared","requestId":"request-4","expiresAtUnixMs":1750000000004}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"omarchy-browser","requestId":"../unsafe","expiresAtUnixMs":1750000000005}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"omarchy-browser","expiresAtUnixMs":1750000000006}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"omarchy-browser","requestId":"request-missing-expiry"}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"omarchy-browser","requestId":"request-string-expiry","expiresAtUnixMs":"1750000000007"}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"omarchy-browser","requestId":"request-fractional-expiry","expiresAtUnixMs":1750000000007.5}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"omarchy-browser","requestId":"request-negative-expiry","expiresAtUnixMs":-1}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"android-launch-app","requestId":"request-package-missing","expiresAtUnixMs":1750000000008}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"android-launch-app","actionArgument":"bad package","requestId":"request-package-invalid","expiresAtUnixMs":1750000000009}}"#
        ),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"android-home","actionArgument":"com.example.notes","requestId":"request-unexpected-argument","expiresAtUnixMs":1750000000010}}"#
        ),
    ] {
        assert_eq!(
            engine.handle_line(&command),
            [format!(
                r#"{{"version":{PROTOCOL_VERSION},"type":"protocol-error","reason":"invalid-command"}}"#
            )]
        );
    }

    let backend = engine.into_backend();
    assert_eq!(
        backend.semantic_actions,
        [
            SemanticAction::OmarchyBrowser,
            SemanticAction::OmarchyCloseCurrentWindow,
            SemanticAction::OmarchyMenu,
            SemanticAction::AndroidLaunchApp,
        ]
    );
    assert_eq!(
        backend.semantic_action_arguments,
        [None, None, None, Some("com.example.notes".to_owned())]
    );
    assert_eq!(
        backend.semantic_request_ids,
        ["request-1", "request-2", "request-3", "request-package"]
    );
    assert_eq!(
        backend.semantic_expires_at_unix_ms,
        [
            1_750_000_000_001,
            1_750_000_000_002,
            1_750_000_000_003,
            1_750_000_000_004,
        ]
    );
}

#[test]
fn failed_semantic_actions_still_emit_a_correlated_unhandled_result() {
    struct FailedActionBackend;

    impl PairingBackend for FailedActionBackend {
        fn start_qr_pairing(&mut self) -> Result<QrPresentation, FailureReason> {
            unreachable!("semantic action test")
        }

        fn cancel_pairing(&mut self) {}

        fn submit_manual_code(&mut self, _code: &str) -> Result<(), FailureReason> {
            unreachable!("semantic action test")
        }

        fn semantic_action(
            &mut self,
            _action: SemanticAction,
            _action_argument: Option<&str>,
            _request_id: &str,
            _expires_at_unix_ms: u64,
        ) -> Result<bool, FailureReason> {
            Err(FailureReason::Disconnected)
        }
    }

    let mut engine = ProtocolEngine::new(FailedActionBackend);
    assert_eq!(
        engine.handle_line(&format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"semantic-action","actionId":"omarchy-browser","requestId":"request-failed","expiresAtUnixMs":1750000000008}}"#
        )),
        [
            format!(
                r#"{{"version":{PROTOCOL_VERSION},"type":"action-result","actionId":"omarchy-browser","requestId":"request-failed","handled":false}}"#
            ),
            format!(
                r#"{{"version":{PROTOCOL_VERSION},"type":"failure","reason":"disconnected"}}"#
            )
        ]
    );
}
#[test]
fn malformed_input_is_rejected_before_reaching_the_backend() {
    let mut engine = ProtocolEngine::new(FakePairingBackend::default());
    let invalid_commands = [
        r#"{"version":9,"type":"pointer-tap","x":1.01,"y":0.5,"displayWidth":1080,"displayHeight":2400}"#,
        r#"{"version":9,"type":"pointer-tap","x":0.5,"y":0.5,"displayWidth":0,"displayHeight":2400}"#,
        r#"{"version":9,"type":"pointer-swipe","startX":0.1,"startY":0.2,"endX":0.8,"endY":0.9,"displayWidth":1080,"displayHeight":2400,"durationMs":0}"#,
        r#"{"version":9,"type":"text-input","text":"line\nfeed"}"#,
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
    let unknown = engine.handle_line(r#"{"version":9,"type":"unknown"}"#);
    let mismatched = engine.handle_line(r#"{"version":10,"type":"start-qr-pairing"}"#);

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
        engine.handle_line(r#"{"version":9,"type":"start-qr-pairing"}"#),
        [format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"failure","reason":"dependency-unavailable"}}"#
        )]
    );
}

#[test]
fn session_started_reports_only_bounded_physical_dimensions() {
    assert_eq!(
        Event::SessionStarted {
            physical_width_mm: Some(70),
            physical_height_mm: Some(157),
        }
        .to_line(),
        format!(
            r#"{{"version":{PROTOCOL_VERSION},"type":"session-started","physicalWidthMm":70,"physicalHeightMm":157}}"#
        )
    );
}
