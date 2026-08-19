use std::collections::VecDeque;

use droid_peek_helper::{
    input::{AdbInputAdapter, AndroidKey, DisplayGeometry, NormalizedPoint},
    process::{CancellationToken, CommandFailure, CommandOutput, CommandRequest, CommandRunner},
};

#[derive(Default)]
struct FakeRunner {
    requests: Vec<CommandRequest>,
    outputs: VecDeque<Result<CommandOutput, CommandFailure>>,
}

impl CommandRunner for FakeRunner {
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

fn geometry() -> DisplayGeometry {
    DisplayGeometry::new(1080, 2400).expect("valid display geometry")
}

#[test]
fn normalized_points_map_to_android_pixel_bounds() {
    let size = geometry();

    assert_eq!(
        NormalizedPoint::new(0.0, 0.0)
            .expect("origin")
            .to_pixels(size),
        (0, 0)
    );
    assert_eq!(
        NormalizedPoint::new(1.0, 1.0)
            .expect("far corner")
            .to_pixels(size),
        (1079, 2399)
    );
    assert_eq!(
        NormalizedPoint::new(0.5, 0.5)
            .expect("center")
            .to_pixels(size),
        (540, 1200)
    );
}

#[test]
fn invalid_geometry_and_points_are_rejected() {
    assert!(DisplayGeometry::new(0, 2400).is_none());
    assert!(DisplayGeometry::new(1080, 0).is_none());
    assert!(NormalizedPoint::new(-0.01, 0.5).is_none());
    assert!(NormalizedPoint::new(0.5, 1.01).is_none());
    assert!(NormalizedPoint::new(f64::NAN, 0.5).is_none());
}

#[test]
fn adb_adapter_builds_targeted_tap_and_swipe_commands() {
    let mut runner = FakeRunner::default();
    let cancellation = CancellationToken::new();
    let mut adapter = AdbInputAdapter::new(&mut runner, &cancellation);
    let start = NormalizedPoint::new(0.25, 0.75).expect("start");
    let end = NormalizedPoint::new(0.75, 0.25).expect("end");

    adapter
        .tap("device.local:38100", geometry(), start)
        .expect("tap succeeds");
    adapter
        .swipe("device.local:38100", geometry(), start, end, 275)
        .expect("swipe succeeds");

    assert_eq!(runner.requests.len(), 2);
    assert_eq!(runner.requests[0].program(), "adb");
    assert_eq!(
        runner.requests[0].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "input",
            "tap",
            "270",
            "1799"
        ]
    );
    assert_eq!(
        runner.requests[1].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "input",
            "swipe",
            "270",
            "1799",
            "809",
            "600",
            "275"
        ]
    );
}

#[test]
fn adb_adapter_maps_keys_and_quotes_remote_shell_text() {
    let mut runner = FakeRunner::default();
    let cancellation = CancellationToken::new();
    let mut adapter = AdbInputAdapter::new(&mut runner, &cancellation);

    adapter
        .key("device.local:38100", AndroidKey::Back)
        .expect("back succeeds");
    adapter
        .key("device.local:38100", AndroidKey::Enter)
        .expect("enter succeeds");
    adapter
        .text("device.local:38100", "hello world")
        .expect("text succeeds");
    adapter
        .text("device.local:38100", "safe'; echo no")
        .expect("quoted text succeeds");
    adapter
        .text("device.local:38100", "100%sure")
        .expect("literal percent-s text succeeds");

    assert_eq!(
        runner.requests[0].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "input",
            "keyevent",
            "KEYCODE_BACK"
        ]
    );
    assert_eq!(
        runner.requests[1].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "input",
            "keyevent",
            "KEYCODE_ENTER"
        ]
    );
    assert_eq!(
        runner.requests[2].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "input",
            "text",
            "'hello%sworld'"
        ]
    );
    assert_eq!(
        runner.requests[3].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "input",
            "text",
            "'safe'\\'';%secho%sno'"
        ]
    );
    assert_eq!(
        runner.requests[4].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "input",
            "text",
            "'100%'"
        ]
    );
    assert_eq!(
        runner.requests[5].arguments(),
        [
            "-s",
            "device.local:38100",
            "shell",
            "input",
            "text",
            "'sure'"
        ]
    );
}

#[test]
fn adb_adapter_reports_unsuccessful_and_cancelled_commands() {
    let mut runner = FakeRunner {
        requests: Vec::new(),
        outputs: VecDeque::from([
            Ok(CommandOutput { succeeded: false }),
            Err(CommandFailure::Cancelled),
        ]),
    };
    let cancellation = CancellationToken::new();
    let mut adapter = AdbInputAdapter::new(&mut runner, &cancellation);
    let point = NormalizedPoint::new(0.5, 0.5).expect("point");

    assert!(
        adapter
            .tap("device.local:38100", geometry(), point)
            .is_err()
    );
    assert!(adapter.key("device.local:38100", AndroidKey::Home).is_err());
}
