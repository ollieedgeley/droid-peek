use std::collections::VecDeque;

use omarchy_android_helper::{
    actions::{AdbActionAdapter, PhoneTarget},
    process::{CancellationToken, CommandFailure, CommandOutput, CommandRequest, CommandRunner},
};

#[test]
fn phone_targets_are_a_small_typed_allowlist() {
    for (wire, expected) in [
        (r#""android.browser.default""#, PhoneTarget::BrowserDefault),
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
}

#[test]
fn phone_targets_reject_unknown_shapes_packages_and_command_source() {
    for target in [
        r#""android.launcher.search""#,
        r#""android.shell""#,
        r#"{"type":"android.app.launch","package":"bad package"}"#,
        r#"{"type":"android.app.launch","package":"com.example.notes","command":"id"}"#,
        r#"{"type":"adb.command","command":"shell input keyevent HOME"}"#,
        r#"{"target":"android.navigate.home"}"#,
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
        _cancellation: &CancellationToken,
    ) -> Result<CommandOutput, CommandFailure> {
        self.requests.push(request);
        self.outputs
            .pop_front()
            .unwrap_or(Ok(CommandOutput { succeeded: true }))
    }
}

#[test]
fn browser_target_resumes_or_launches_the_selected_browser_without_a_url() {
    let mut runner = FakeActionRunner::default();
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    assert_eq!(
        adapter.execute("device.local:38100", &PhoneTarget::BrowserDefault),
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
            "am",
            "start",
            "-W",
            "-a",
            "android.intent.action.MAIN",
            "-c",
            "android.intent.category.APP_BROWSER",
        ]
    );
    assert!(runner.requests[0].arguments().iter().all(|argument| {
        !argument.contains("://") && argument != "--package" && argument != "-n"
    }));
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
        requests: Vec::new(),
        outputs: VecDeque::from([
            Ok(CommandOutput { succeeded: false }),
            Err(CommandFailure::Cancelled),
        ]),
    };
    let cancellation = CancellationToken::new();
    let mut adapter = AdbActionAdapter::new(&mut runner, &cancellation);

    assert_eq!(
        adapter.execute("device.local:38100", &PhoneTarget::BrowserDefault),
        Ok(false)
    );
    assert_eq!(
        adapter.execute("device.local:38100", &PhoneTarget::NavigateHome),
        Err(CommandFailure::Cancelled)
    );
}
