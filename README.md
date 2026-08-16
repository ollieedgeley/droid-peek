# Omarchy Android

An Omarchy bar-widget plugin for pairing and controlling one Android phone over
Wireless debugging. It uses QR-first ADB pairing, unmodified scrcpy for video,
and a QML panel designed to feel native to Omarchy.

## Current stage

The panel and helper implement QR-first and six-digit fallback pairing through
bounded Avahi discovery and ADB subprocesses. Automated coverage uses fake
executables only. A live OxygenOS 16 / Android 16 run passed QR pairing,
six-digit fallback, and cancel/retry for both paths; Android 14 and 15 remain
release acceptance targets. Remembered-device reconnection, scrcpy, V4L2
playback, and input forwarding are not yet implemented. The project does not
install system dependencies.

## Layout

- `BarWidget.qml` and `Panel.qml`: the Omarchy bar-widget shell surface.
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
