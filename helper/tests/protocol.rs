use omarchy_android_helper::actions::PhoneTarget;
use omarchy_android_helper::input::{AndroidKey, DisplayGeometry, NormalizedPoint};
use omarchy_android_helper::preferences::{Preferences, PreviewScale, QuickAction, VideoQuality};
use omarchy_android_helper::protocol::{
    ActionFailureCode, Event, FailureReason, PROTOCOL_VERSION, PairingBackend,
    PairingRequestFailure, PhoneTargetFailure, ProtocolEngine, QrPresentation,
};

const HELPER_EPOCH: &str = "73001";

fn engine(backend: FakePairingBackend) -> ProtocolEngine<FakePairingBackend> {
    ProtocolEngine::new(backend, HELPER_EPOCH)
}

fn wire_lines(events: Vec<Event>) -> Vec<String> {
    events.into_iter().map(|event| event.to_line()).collect()
}

#[derive(Default)]
struct FakePairingBackend {
    manual_codes: Vec<String>,
    pairing_cancels: usize,
    reconnects: usize,
    session_stops: usize,
    start_overs: usize,
    session_generation: u64,
    pointer_taps: Vec<(DisplayGeometry, NormalizedPoint)>,
    pointer_swipes: Vec<(DisplayGeometry, NormalizedPoint, NormalizedPoint, u32)>,
    keys: Vec<AndroidKey>,
    texts: Vec<String>,
    phone_targets: Vec<(PhoneTarget, String, u64)>,
    phone_target_failure: Option<PhoneTargetFailure>,
    preference_updates: Vec<Preferences>,
}

impl PairingBackend for FakePairingBackend {
    fn start_qr_pairing(&mut self) -> Result<QrPresentation, PairingRequestFailure> {
        Ok(QrPresentation {
            artifact: "/run/user/1000/omarchy-android/qr.svg".into(),
            expires_in_seconds: 120,
        })
    }

    fn cancel_pairing(&mut self) {
        self.pairing_cancels += 1;
    }

    fn submit_manual_code(&mut self, code: &str) -> Result<(), PairingRequestFailure> {
        self.manual_codes.push(code.to_owned());
        Ok(())
    }

    fn session_generation(&self) -> u64 {
        self.session_generation
    }

    fn reconnect_trusted_device(&mut self) -> Result<(), FailureReason> {
        self.reconnects += 1;
        self.session_generation += 1;
        Ok(())
    }

    fn stop_session(&mut self) {
        self.session_stops += 1;
        self.session_generation += 1;
    }

    fn start_over(&mut self) -> Result<(), FailureReason> {
        self.start_overs += 1;
        self.session_generation += 1;
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

    fn text_input(&mut self, text: &str) -> Result<(), FailureReason> {
        self.texts.push(text.to_owned());
        Ok(())
    }

    fn phone_target(
        &mut self,
        target: PhoneTarget,
        request_id: &str,
        expires_at_unix_ms: u64,
    ) -> Result<(), PhoneTargetFailure> {
        self.phone_targets
            .push((target, request_id.to_owned(), expires_at_unix_ms));
        match self.phone_target_failure.take() {
            Some(PhoneTargetFailure::Lifecycle(reason)) => {
                self.session_generation += 1;
                Err(PhoneTargetFailure::Lifecycle(reason))
            }
            Some(failure) => Err(failure),
            None => Ok(()),
        }
    }

    fn preferences(&self) -> Preferences {
        self.preference_updates.last().copied().unwrap_or_default()
    }

    fn set_preferences(&mut self, preferences: Preferences) -> Result<bool, FailureReason> {
        let restarted = preferences.video_quality != self.preferences().video_quality;
        self.preference_updates.push(preferences);
        if restarted {
            self.session_generation += 1;
        }
        Ok(restarted)
    }
}

#[test]
fn backend_shutdown_cancels_pairing_and_advances_session_generation() {
    let engine = engine(FakePairingBackend::default());
    let mut backend = engine.into_backend();

    backend.shutdown();

    assert_eq!(backend.pairing_cancels, 1);
    assert_eq!(backend.session_stops, 1);
    assert_eq!(backend.session_generation, 1);
}

#[test]
fn protocol_version_eleven_ready_establishes_epoch_and_generation_zero() {
    assert_eq!(PROTOCOL_VERSION, 11);
    assert_eq!(
        Event::Ready {
            helper_epoch: HELPER_EPOCH.to_owned(),
            session_generation: "0".to_owned(),
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
        r#"{"version":11,"type":"ready","helperEpoch":"73001","sessionGeneration":"0","hasTrustedDevice":true,"preferences":{"keepConnected":true,"androidModeShortcuts":true,"previewScale":125,"videoQuality":"low","quickActions":["home","recent-apps","back"]}}"#
    );
}

#[test]
fn replacement_helper_uses_a_new_epoch_and_resets_its_generation_baseline() {
    let ready = |helper_epoch: &str| Event::Ready {
        helper_epoch: helper_epoch.to_owned(),
        session_generation: "0".to_owned(),
        has_trusted_device: true,
        preferences: Preferences::default(),
    };

    let first: serde_json::Value =
        serde_json::from_str(&ready("73001").to_line()).expect("first ready event");
    let replacement: serde_json::Value =
        serde_json::from_str(&ready("73002").to_line()).expect("replacement ready event");

    assert_eq!(first["helperEpoch"], "73001");
    assert_eq!(replacement["helperEpoch"], "73002");
    assert_eq!(first["sessionGeneration"], "0");
    assert_eq!(replacement["sessionGeneration"], "0");
}

#[test]
fn pairing_only_events_carry_epoch_but_no_session_generation() {
    let mut engine = engine(FakePairingBackend::default());

    for (command, expected_type) in [
        ("start-qr-pairing", "qr-waiting"),
        ("cancel-pairing", "pairing-cancelled"),
        ("use-manual-code", "manual-code-required"),
    ] {
        let events = wire_lines(engine.handle_line(&format!(
            r#"{{"version":11,"type":"{command}","helperEpoch":"{HELPER_EPOCH}"}}"#
        )));
        let value: serde_json::Value =
            serde_json::from_str(&events[0]).expect("valid protocol event");
        assert_eq!(value["type"], expected_type);
        assert_eq!(value["helperEpoch"], HELPER_EPOCH);
        assert!(value.get("sessionGeneration").is_none());
    }
}

#[test]
fn manual_code_is_consumed_without_appearing_in_events() {
    let mut engine = engine(FakePairingBackend::default());
    let code = "123456";
    let events = wire_lines(engine.handle_line(&format!(
        r#"{{"version":11,"type":"submit-manual-code","helperEpoch":"{HELPER_EPOCH}","code":"{code}"}}"#
    )));

    assert_eq!(
        events,
        [format!(
            r#"{{"version":11,"type":"pairing","helperEpoch":"{HELPER_EPOCH}","method":"manual-code"}}"#
        )]
    );
    assert!(events.iter().all(|event| !event.contains(code)));
    assert_eq!(engine.into_backend().manual_codes, [code]);
}

#[test]
fn reconnect_stop_and_start_over_advance_generation_before_their_events() {
    let mut engine = engine(FakePairingBackend::default());

    for (command, identity, event_type, generation) in [
        ("reconnect-trusted-device", "", "connecting", "1"),
        (
            "stop-session",
            r#","sessionGeneration":"1""#,
            "session-stopped",
            "2",
        ),
        (
            "start-over",
            r#","sessionGeneration":"2""#,
            "start-over-complete",
            "3",
        ),
    ] {
        assert_eq!(
            wire_lines(engine.handle_line(&format!(
                r#"{{"version":11,"type":"{command}","helperEpoch":"{HELPER_EPOCH}"{identity}}}"#
            ))),
            [format!(
                r#"{{"version":11,"type":"{event_type}","helperEpoch":"{HELPER_EPOCH}","sessionGeneration":"{generation}"}}"#
            )]
        );
    }

    let backend = engine.into_backend();
    assert_eq!(backend.reconnects, 1);
    assert_eq!(backend.session_stops, 1);
    assert_eq!(backend.start_overs, 1);
}

#[test]
fn preferences_are_schema_one_and_quality_restart_advances_generation() {
    let mut engine = engine(FakePairingBackend::default());

    assert_eq!(
        wire_lines(engine.handle_line(
            r#"{"version":11,"type":"set-preferences","helperEpoch":"73001","keepConnected":true,"androidModeShortcuts":false,"previewScale":150,"videoQuality":"low","quickActions":["home","recent-apps","back"]}"#,
        )),
        [r#"{"version":11,"type":"preferences-updated","helperEpoch":"73001","sessionGeneration":"1","keepConnected":true,"androidModeShortcuts":false,"previewScale":150,"videoQuality":"low","quickActions":["home","recent-apps","back"],"sessionRestarted":true}"#]
    );

    let backend = engine.into_backend();
    assert_eq!(
        backend.preference_updates,
        [Preferences {
            keep_connected: true,
            android_mode_shortcuts: false,
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
fn missing_or_retired_preference_fields_do_not_reach_the_backend() {
    let mut engine = engine(FakePairingBackend::default());
    for command in [
        r#"{"version":11,"type":"set-preferences","helperEpoch":"73001","androidModeShortcuts":true,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":11,"type":"set-preferences","helperEpoch":"73001","keepConnected":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
        r#"{"version":11,"type":"set-preferences","helperEpoch":"73001","keepConnected":false,"androidModeShortcuts":true,"commandPassthrough":false,"previewScale":100,"videoQuality":"high","quickActions":["back","home","recent-apps"]}"#,
    ] {
        assert_eq!(
            wire_lines(engine.handle_line(command)),
            [
                r#"{"version":11,"type":"protocol-error","helperEpoch":"73001","reason":"invalid-command"}"#
            ]
        );
    }
    assert!(engine.into_backend().preference_updates.is_empty());
}

#[test]
fn matching_session_bound_input_is_validated_and_forwarded() {
    let mut engine = engine(FakePairingBackend::default());
    for command in [
        r#"{"version":11,"type":"pointer-tap","helperEpoch":"73001","sessionGeneration":"0","x":0.25,"y":0.75,"displayWidth":1080,"displayHeight":2400}"#,
        r#"{"version":11,"type":"pointer-swipe","helperEpoch":"73001","sessionGeneration":"0","startX":0.1,"startY":0.2,"endX":0.8,"endY":0.9,"displayWidth":1080,"displayHeight":2400,"durationMs":320}"#,
        r#"{"version":11,"type":"key-input","helperEpoch":"73001","sessionGeneration":"0","key":"back"}"#,
        r#"{"version":11,"type":"text-input","helperEpoch":"73001","sessionGeneration":"0","text":"a"}"#,
    ] {
        assert!(engine.handle_line(command).is_empty());
    }

    let backend = engine.into_backend();
    assert_eq!(backend.pointer_taps.len(), 1);
    assert_eq!(backend.pointer_swipes.len(), 1);
    assert_eq!(backend.keys, [AndroidKey::Back]);
    assert_eq!(backend.texts, ["a"]);
}

#[test]
fn stale_or_missing_identity_rejects_every_session_bound_command_before_backend_work() {
    let backend = FakePairingBackend {
        session_generation: 7,
        ..FakePairingBackend::default()
    };
    let mut engine = engine(backend);
    let commands = [
        r#"{"version":11,"type":"pointer-tap","helperEpoch":"73000","sessionGeneration":"7","x":0.5,"y":0.5,"displayWidth":1080,"displayHeight":2400}"#,
        r#"{"version":11,"type":"pointer-swipe","helperEpoch":"73001","sessionGeneration":"6","startX":0.1,"startY":0.2,"endX":0.8,"endY":0.9,"displayWidth":1080,"displayHeight":2400,"durationMs":320}"#,
        r#"{"version":11,"type":"key-input","helperEpoch":"73001","key":"home"}"#,
        r#"{"version":11,"type":"text-input","sessionGeneration":"7","text":"never type this"}"#,
        r#"{"version":11,"type":"phone-target","helperEpoch":"73001","sessionGeneration":"8","requestId":"stale-target","expiresAtUnixMs":1750000000001,"target":"android.navigate.home"}"#,
    ];

    for command in commands {
        let events = wire_lines(engine.handle_line(command));
        assert_eq!(events.len(), 1);
        let event: serde_json::Value =
            serde_json::from_str(&events[0]).expect("typed stale-session result");
        assert_eq!(event["type"], "action-result");
        assert_eq!(event["outcome"], "stale-session");
        assert_eq!(event["helperEpoch"], HELPER_EPOCH);
        assert_eq!(event["sessionGeneration"], "7");
    }

    let backend = engine.into_backend();
    assert!(backend.pointer_taps.is_empty());
    assert!(backend.pointer_swipes.is_empty());
    assert!(backend.keys.is_empty());
    assert!(backend.texts.is_empty());
    assert!(backend.phone_targets.is_empty());
}

#[test]
fn invalid_phone_target_request_ids_are_rejected_before_stale_identity_can_echo_them() {
    let backend = FakePairingBackend {
        session_generation: 7,
        ..FakePairingBackend::default()
    };
    let mut engine = engine(backend);

    for command in [
        r#"{"version":11,"type":"phone-target","helperEpoch":"73000","sessionGeneration":"7","requestId":"invalid/request","expiresAtUnixMs":1750000000001,"target":"android.navigate.home"}"#,
        r#"{"version":11,"type":"phone-target","helperEpoch":"73001","sessionGeneration":"6","requestId":"invalid request","expiresAtUnixMs":1750000000001,"target":"android.navigate.home"}"#,
    ] {
        assert_eq!(
            wire_lines(engine.handle_line(command)),
            [
                r#"{"version":11,"type":"protocol-error","helperEpoch":"73001","reason":"invalid-command"}"#
            ]
        );
    }

    assert!(engine.into_backend().phone_targets.is_empty());
}

#[test]
fn typed_phone_targets_are_correlated_and_forwarded_with_identity() {
    let mut engine = engine(FakePairingBackend::default());
    for (request_id, target) in [
        ("browser", r#""android.browser.default""#),
        ("home", r#""android.navigate.home""#),
        (
            "package",
            r#"{"type":"android.app.launch","package":"com.example.notes"}"#,
        ),
    ] {
        assert_eq!(
            wire_lines(engine.handle_line(&format!(
                r#"{{"version":11,"type":"phone-target","helperEpoch":"{HELPER_EPOCH}","sessionGeneration":"0","requestId":"{request_id}","expiresAtUnixMs":1750000000001,"target":{target}}}"#
            ))),
            [format!(
                r#"{{"version":11,"type":"action-result","helperEpoch":"{HELPER_EPOCH}","sessionGeneration":"0","requestId":"{request_id}","outcome":"completed"}}"#
            )]
        );
    }

    let backend = engine.into_backend();
    assert_eq!(backend.phone_targets.len(), 3);
    assert_eq!(backend.phone_targets[0].0, PhoneTarget::BrowserDefault);
    assert_eq!(backend.phone_targets[1].0, PhoneTarget::NavigateHome);
    assert_eq!(
        backend.phone_targets[2].0,
        PhoneTarget::AppLaunch {
            package: "com.example.notes".to_owned()
        }
    );
}

#[test]
fn action_only_failure_is_typed_and_does_not_emit_a_lifecycle_failure() {
    let mut engine = engine(FakePairingBackend {
        phone_target_failure: Some(PhoneTargetFailure::ActionOnly(
            ActionFailureCode::TargetFailed,
        )),
        ..FakePairingBackend::default()
    });

    assert_eq!(
        wire_lines(engine.handle_line(
            r#"{"version":11,"type":"phone-target","helperEpoch":"73001","sessionGeneration":"0","requestId":"failed-browser","expiresAtUnixMs":1750000000001,"target":"android.browser.default"}"#,
        )),
        [r#"{"version":11,"type":"action-result","helperEpoch":"73001","sessionGeneration":"0","requestId":"failed-browser","outcome":"failed","notificationCode":"target-failed"}"#]
    );
}

#[test]
fn proven_transport_failure_is_a_separate_generation_advancing_lifecycle_event() {
    let mut engine = engine(FakePairingBackend {
        phone_target_failure: Some(PhoneTargetFailure::Lifecycle(FailureReason::Disconnected)),
        ..FakePairingBackend::default()
    });

    assert_eq!(
        wire_lines(engine.handle_line(
            r#"{"version":11,"type":"phone-target","helperEpoch":"73001","sessionGeneration":"0","requestId":"lost-device","expiresAtUnixMs":1750000000001,"target":"android.navigate.home"}"#,
        )),
        [
            r#"{"version":11,"type":"action-result","helperEpoch":"73001","sessionGeneration":"0","requestId":"lost-device","outcome":"failed","notificationCode":"target-failed"}"#,
            r#"{"version":11,"type":"lifecycle-failure","helperEpoch":"73001","sessionGeneration":"1","reason":"disconnected"}"#,
        ]
    );
}

#[test]
fn malformed_or_unknown_targets_fail_closed_before_android_work() {
    let mut engine = engine(FakePairingBackend::default());
    for target in [
        r#""not-declared""#,
        r#"{"type":"android.app.launch","package":"bad package"}"#,
        r#"{"type":"adb.command","command":"shell id"}"#,
    ] {
        assert_eq!(
            wire_lines(engine.handle_line(&format!(
                r#"{{"version":11,"type":"phone-target","helperEpoch":"{HELPER_EPOCH}","sessionGeneration":"0","requestId":"invalid-target","expiresAtUnixMs":1750000000001,"target":{target}}}"#
            ))),
            [format!(
                r#"{{"version":11,"type":"action-result","helperEpoch":"{HELPER_EPOCH}","sessionGeneration":"0","requestId":"invalid-target","outcome":"failed","notificationCode":"invalid-target"}}"#
            )]
        );
    }
    assert!(engine.into_backend().phone_targets.is_empty());
}

#[test]
fn malformed_unknown_and_v10_commands_fail_without_echoing_input() {
    let mut engine = engine(FakePairingBackend::default());
    let secret = "do-not-echo";
    let malformed = wire_lines(engine.handle_line(&format!(r#"{{"secret":"{secret}"}}"#)));
    let unknown =
        wire_lines(engine.handle_line(r#"{"version":11,"type":"unknown","helperEpoch":"73001"}"#));
    let retired = wire_lines(
        engine.handle_line(r#"{"version":10,"type":"start-qr-pairing","helperEpoch":"73001"}"#),
    );

    assert_eq!(
        malformed,
        [
            r#"{"version":11,"type":"protocol-error","helperEpoch":"73001","reason":"invalid-command"}"#
        ]
    );
    assert_eq!(unknown, malformed);
    assert_eq!(
        retired,
        [
            r#"{"version":11,"type":"protocol-error","helperEpoch":"73001","reason":"version-mismatch"}"#
        ]
    );
    assert!(malformed.iter().all(|event| !event.contains(secret)));
}

#[test]
fn session_started_reports_two_part_identity_and_bounded_dimensions() {
    assert_eq!(
        Event::SessionStarted {
            helper_epoch: HELPER_EPOCH.to_owned(),
            session_generation: "9".to_owned(),
            physical_width_mm: Some(70),
            physical_height_mm: Some(157),
        }
        .to_line(),
        r#"{"version":11,"type":"session-started","helperEpoch":"73001","sessionGeneration":"9","physicalWidthMm":70,"physicalHeightMm":157}"#
    );
}
