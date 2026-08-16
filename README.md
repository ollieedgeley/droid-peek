# Omarchy Android

An Omarchy bar-widget plugin for pairing and controlling one Android phone over
Wireless debugging. It uses QR-first ADB pairing, unmodified scrcpy for video,
and a QML panel designed to feel native to Omarchy.

## Current stage

The panel and helper implement QR-first and six-digit fallback pairing through
bounded Avahi discovery and ADB subprocesses. The helper privately remembers
only the selected Android connection-service identity, resolves its current
endpoint, and orchestrates a cancellable, headless scrcpy session against that
in-memory target. scrcpy output is discarded, raw endpoints never cross the
protocol boundary, and panel close waits for the child process to stop.

The ready panel captures the private `Omarchy Android` V4L2 device through Qt
Multimedia and releases it when the panel closes. Its focused input surface
maps aspect-fit pointer coordinates and keyboard intent into versioned helper
commands; the helper validates them and runs targeted Android `input` commands
through its fakeable ADB boundary. Production uses `/dev/video42` by default;
`OMARCHY_ANDROID_V4L2_SINK` overrides the private sink path.

Phase 0 is complete for the V1 Android 16 target. The development machine proved
synthetic 360×640 playback at 30 fps and clean stop/restart behavior with
`v4l2loopback` 0.15.4. A physical CPH2719 running OxygenOS 16 / Android 16 then
proved real 1080×2392 QML playback, session and capture restart, pointer input,
Back, Home, recent apps, and typed input. QR pairing, six-digit fallback, and
cancel/retry had already passed on the same platform.

Other Android versions are deferred until the application is complete and
require explicit emulator and physical-device evidence before support is
claimed. The project does not install or load system dependencies.

## Layout

- `BarWidget.qml` and `Panel.qml`: the Omarchy bar-widget shell surface.
- `actions.json`: the versioned, classified semantic action contract.
- `helper/`: the local Rust helper and its pure contract tests.
- `tests/qml/`: Qt Quick Test coverage for panel-local state.
- `scripts/check.sh`: the deterministic local verification entry point.

## Checks

Run `./scripts/check.sh` from the repository root. It validates the Omarchy
manifest, uses the Qt 6 tooling paired with Quickshell, runs QML tests, and
runs Rust format, lint, and test checks. The script builds a temporary import
map for Omarchy's root-relative `qs.*` modules, so QML linting remains a clean
gate without altering the user’s shell or suppressing warnings.

Read `SPEC.md` for the product contract and `AGENTS.md` before implementing
behavior.
