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

The ready view includes Back, Home, and recent-apps controls plus an inline
render-settings page. Preview scale accepts 50% through 150%, defaults to 100%,
and changes the anchored panel immediately. Video quality selects a scrcpy
profile and restarts only the active mirroring session; the trusted pairing
and selected controls remain intact. Preferences are stored privately with the
remembered-device record.

Phase 0 is complete for the V1 Android 16 target. The development machine proved
synthetic 360×640 playback at 30 fps and clean stop/restart behavior with
`v4l2loopback` 0.15.4. A physical CPH2719 running OxygenOS 16 / Android 16 then
proved real 1080×2392 QML playback, session and capture restart, pointer input,
Back, Home, recent apps, and typed input. QR pairing, six-digit fallback, and
cancel/retry had already passed on the same platform.

Other Android versions are deferred until the application is complete and
require explicit emulator and physical-device evidence before support is
claimed. The project does not install or load system dependencies.

## Requirements

V1 supports Android 16 on a trusted local network. The Android phone or emulator
must have Wireless debugging enabled. The host requires:

- Omarchy with the current Quickshell bar-plugin runtime.
- Rust and Cargo to build the local helper.
- `android-tools`, `avahi`, `scrcpy`, and `qt6-multimedia`.
- `v4l2loopback-dkms` plus the headers for the running kernel.
- A private V4L2 loopback device at `/dev/video42`, labeled `Omarchy Android`.

Installing packages, enabling Avahi, and loading a kernel module are explicit
system changes. This repository performs none of them. On Omarchy, review and
run the following only when those changes are acceptable:

```bash
omarchy pkg add android-tools avahi scrcpy qt6-multimedia v4l2loopback-dkms
sudo systemctl enable --now avahi-daemon.service
sudo modprobe v4l2loopback devices=1 video_nr=42 card_label=\"Omarchy Android\" exclusive_caps=1
```

The module load lasts until reboot. Persisting it requires a deliberate local
`modules-load.d` and `modprobe.d` configuration; the plugin does not write
either file. Confirm the private device before starting the plugin:

```bash
v4l2-ctl --list-devices
```

The output must associate `Omarchy Android` with `/dev/video42`. Set
`OMARCHY_ANDROID_V4L2_SINK` for the helper if a different private path is
required; the loopback label must remain `Omarchy Android` for Qt Multimedia
discovery.

## Install from this checkout

Plugins execute unsandboxed inside the long-running `omarchy-shell` process.
Review this repository and its updates before enabling it. The Rust helper is a
separate child process with access to ADB, Avahi, scrcpy, and the private state
directory.

From the repository root:

```bash
cargo build --release --manifest-path helper/Cargo.toml
install -Dm755 helper/target/release/omarchy-android-helper \
  \"$HOME/.local/bin/omarchy-android-helper\"
mkdir -p \"$HOME/.config/omarchy/plugins\"
ln -s "$PWD" "$HOME/.config/omarchy/plugins/ollie.android"
omarchy-shell shell rescanPlugins
omarchy plugin enable ollie.android
```

`~/.local/bin` must be on the environment inherited by `omarchy-shell`.
Saving files in the linked checkout reloads the plugin automatically. A
published release can instead be added with `omarchy plugin add` using its Git
repository URL, then build and install the helper from the resulting
`~/.config/omarchy/plugins/ollie.android` checkout.

No Omarchy configuration is overwritten by these steps. Enabling the plugin
adds its widget to the persisted bar layout through Omarchy's supported plugin
command.

## Remove

Disable the widget before removing files:

```bash
omarchy plugin disable ollie.android
rm \"$HOME/.config/omarchy/plugins/ollie.android\"
rm -f \"$HOME/.local/bin/omarchy-android-helper\"
```

If the plugin was installed with `omarchy plugin add`, use
`omarchy plugin remove ollie.android` instead of removing its checkout
directly. Remembered-device identity and render preferences remain under
`${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-android`; remove that directory
only when forgetting the phone and settings is intended.

Do not unload `v4l2loopback` while another application or loopback device uses
it. System packages, Avahi enablement, module persistence, and kernel headers
are shared dependencies and are intentionally left untouched on plugin
removal.

## Troubleshooting

- **Dependency unavailable:** verify `adb`, `avahi-browse`, `scrcpy`, and
  `omarchy-android-helper` are on the shell's `PATH`. Confirm `/dev/video42`
  exists, has the `Omarchy Android` label, and is writable by the current user.
- **Black or stalled preview:** close the panel, confirm no stale process owns
  `/dev/video42`, then reopen it. The helper starts a fresh producer and the
  panel starts a fresh Qt Multimedia consumer on every session.
- **Unauthorized:** accept the debugging authorization on Android, then retry.
- **Disconnected:** keep both devices on the same trusted Wi-Fi network and
  leave Wireless debugging enabled. Reconnection resolves the remembered mDNS
  service again; stored raw addresses are never used.
- **Reset pairing:** remove the remembered state directory described above,
  reopen the panel, and complete a fresh QR or six-digit pairing.

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
