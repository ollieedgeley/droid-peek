use std::collections::VecDeque;

use droid_peek_helper::{
    actions::{AdbActionAdapter, PhoneTarget},
    input::AndroidKey,
    process::{
        ActionExecutionFailure, CancellationToken, CommandFailure, CommandOutput, CommandRequest,
        CommandRunner,
    },
};

fn key_events() -> [(&'static str, AndroidKey, &'static str); 21] {
    [
        ("back", AndroidKey::Back, "KEYCODE_BACK"),
        ("home", AndroidKey::Home, "KEYCODE_HOME"),
        ("app-switch", AndroidKey::AppSwitch, "KEYCODE_APP_SWITCH"),
        ("enter", AndroidKey::Enter, "KEYCODE_ENTER"),
        ("delete", AndroidKey::Delete, "KEYCODE_DEL"),
        ("escape", AndroidKey::Escape, "KEYCODE_ESCAPE"),
        ("arrow-up", AndroidKey::ArrowUp, "KEYCODE_DPAD_UP"),
        ("arrow-down", AndroidKey::ArrowDown, "KEYCODE_DPAD_DOWN"),
        ("arrow-left", AndroidKey::ArrowLeft, "KEYCODE_DPAD_LEFT"),
        ("arrow-right", AndroidKey::ArrowRight, "KEYCODE_DPAD_RIGHT"),
        ("tab", AndroidKey::Tab, "KEYCODE_TAB"),
        ("space", AndroidKey::Space, "KEYCODE_SPACE"),
        ("volume-up", AndroidKey::VolumeUp, "KEYCODE_VOLUME_UP"),
        ("volume-down", AndroidKey::VolumeDown, "KEYCODE_VOLUME_DOWN"),
        ("volume-mute", AndroidKey::VolumeMute, "KEYCODE_VOLUME_MUTE"),
        (
            "media-play-pause",
            AndroidKey::MediaPlayPause,
            "KEYCODE_MEDIA_PLAY_PAUSE",
        ),
        ("media-next", AndroidKey::MediaNext, "KEYCODE_MEDIA_NEXT"),
        (
            "media-previous",
            AndroidKey::MediaPrevious,
            "KEYCODE_MEDIA_PREVIOUS",
        ),
        ("copy", AndroidKey::Copy, "KEYCODE_COPY"),
        ("cut", AndroidKey::Cut, "KEYCODE_CUT"),
        ("paste", AndroidKey::Paste, "KEYCODE_PASTE"),
    ]
}

#[test]
fn phone_targets_are_a_small_typed_allowlist() {
    for (wire, expected) in [
        (r#""android.navigate.home""#, PhoneTarget::NavigateHome),
        (r#""android.navigate.back""#, PhoneTarget::NavigateBack),
        (r#""android.recent-apps""#, PhoneTarget::RecentApps),
    ] {
        assert_eq!(
            serde_json::from_str::<PhoneTarget>(wire).expect("declared phone target"),
            expected
        );
    }

    assert_eq!(
        serde_json::from_str::<PhoneTarget>(
            r#"{"type":"android.app.launch","package":"com.example.notes"}"#,
        )
        .expect("typed package launch"),
        PhoneTarget::AppLaunch {
            package: "com.example.notes".to_owned(),
        }
    );

    for (name, key, _) in key_events() {
        assert_eq!(
            serde_json::from_str::<PhoneTarget>(&format!(
                r#"{{"type":"android.keyevent","key":"{name}"}}"#
            ))
            .expect("declared Android key event"),
            PhoneTarget::KeyEvent { key }
        );
    }
}

#[test]
fn phone_targets_reject_unknown_shapes_packages_and_command_source() {
    for target in [
        r#""android.browser.default""#,
        r#""android.launcher.search""#,
        r#""android.shell""#,
        r#""android.keyevent""#,
        r#"{"type":"android.app.launch","package":"bad package"}"#,
        r#"{"type":"android.app.launch","package":"com.example.notes","command":"id"}"#,
        r#"{"type":"adb.command","command":"shell input keyevent HOME"}"#,
        r#"{"target":"android.navigate.home"}"#,
        r#"{"type":"android.keyevent"}"#,
        r#"{"key":"volume-up"}"#,
        r#"{"type":"android.keyevent","key":"brightness-up"}"#,
        r#"{"type":"android.keyevent","key":"volume-up","command":"id"}"#,
        r#"{"type":"android.key-event","key":"volume-up"}"#,
        r#"{"type":7,"key":"volume-up"}"#,
        r#"{"type":"android.app.launch","key":"volume-up"}"#,
        r#"{"type":"android.keyevent","key":"KEYCODE_VOLUME_UP"}"#,
        r#"{"type":"android.keyevent","key":24}"#,
        r#"{"type":"android.keyevent","key":["volume-up"]}"#,
        r#"{"type":"android.keyevent","key":null}"#,
        r#"{"type":"android.keyevent","key":"Volume-Up"}"#,
        r#"{"type":"android.keyevent","key":"volume_up"}"#,
        r#"[{"type":"android.keyevent","key":"volume-up"}]"#,
        r#"42"#,
        r#"null"#,
    ] {
        assert!(
            serde_json::from_str::<PhoneTarget>(target).is_err(),
            "unexpectedly accepted {target}"
        );
    }
}

#[derive(Default)]
struct FakeActionRunner {
    requests: Vec<CommandRequest>,
    outputs: VecDeque<Result<CommandOutput, CommandFailure>>,
}

impl CommandRunner for FakeActionRunner {
    fn run(
        &mut self,
        request: CommandRequest,
        cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        if cancellation.is_cancelled() {
            return Err(CommandFailure::Cancelled);
        }
        self.requests.push(request);
        self.outputs
            .pop_front()
            .unwrap_or(Ok(CommandOutput { succeeded: true }))
    }
}

#[test]
fn navigation_targets_use_only_the_declared_android_key() {
    let mut runner = FakeActionRunner::default();
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    for target in [
        PhoneTarget::NavigateHome,
        PhoneTarget::NavigateBack,
        PhoneTarget::RecentApps,
    ] {
        assert_eq!(adapter.execute("device.local:38100", &target), Ok(true));
    }

    let keycodes: Vec<_> = runner
        .requests
        .iter()
        .map(|request| request.arguments().last().expect("keycode").as_str())
        .collect();
    assert_eq!(
        keycodes,
        ["KEYCODE_HOME", "KEYCODE_BACK", "KEYCODE_APP_SWITCH"]
    );
    assert!(runner.requests.iter().all(|request| {
        request.arguments()[0..5] == ["-s", "device.local:38100", "shell", "input", "keyevent"]
    }));
}

#[test]
fn key_event_targets_use_exact_selected_device_and_fixed_keycodes() {
    let mut runner = FakeActionRunner::default();
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    for (_, key, _) in key_events() {
        assert_eq!(
            adapter.execute("device.local:38100", &PhoneTarget::KeyEvent { key },),
            Ok(true)
        );
    }

    for (request, (_, _, keycode)) in runner.requests.iter().zip(key_events()) {
        assert_eq!(
            request.arguments(),
            [
                "-s",
                "device.local:38100",
                "shell",
                "input",
                "keyevent",
                keycode,
            ]
        );
    }
}

#[test]
fn package_target_launches_exactly_one_validated_launcher_activity() {
    let mut runner = FakeActionRunner::default();
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    assert_eq!(
        adapter.execute(
            "device.local:38100",
            &PhoneTarget::AppLaunch {
                package: "com.example.notes".to_owned(),
            },
        ),
        Ok(true)
    );

    assert_eq!(runner.requests.len(), 1);
    assert_eq!(runner.requests[0].program(), "adb");
    assert_eq!(
        runner.requests[0].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "monkey",
            "-p",
            "com.example.notes",
            "-c",
            "android.intent.category.LAUNCHER",
            "1"
        ]
    );
}

#[test]
fn target_adapter_preserves_process_failure_as_an_action_outcome() {
    let mut runner = FakeActionRunner {
        outputs: VecDeque::from([
            Ok(CommandOutput { succeeded: false }),
            Err(CommandFailure::Cancelled),
        ]),
        ..FakeActionRunner::default()
    };
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    assert_eq!(
        adapter.execute("device.local:38100", &PhoneTarget::NavigateHome),
        Ok(false)
    );
    assert_eq!(
        adapter.execute("device.local:38100", &PhoneTarget::NavigateHome),
        Err(ActionExecutionFailure::Cancelled)
    );
}

#[test]
fn cancelled_action_runner_does_not_report_queued_success() {
    let mut runner = FakeActionRunner {
        outputs: VecDeque::from([Ok(CommandOutput { succeeded: true })]),
        ..FakeActionRunner::default()
    };
    let cancellation = CancellationToken::new();
    cancellation.cancel();

    assert_eq!(
        runner.run(
            CommandRequest::new("adb", vec!["version".to_owned()]),
            &cancellation,
        ),
        Err(CommandFailure::Cancelled)
    );
    assert!(runner.requests.is_empty());
}
