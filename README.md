# Omarchy Android

An Omarchy bar-widget plugin for pairing and controlling one Android phone over
Wireless debugging. It uses QR-first ADB pairing, unmodified scrcpy for video,
and a QML panel designed to feel native to Omarchy.

## Current stage

The panel and helper implement QR-first and six-digit fallback pairing through
bounded Avahi discovery and ADB subprocesses. The helper privately remembers
only the selected Android connection-service identity, resolves its current
endpoint, and orchestrates a cancellable, headless scrcpy session against that
in-memory target. scrcpy output is discarded and raw endpoints never cross the
protocol boundary. Panel close stops the child process by default. The optional
**Keep connected** preference retains only an active trusted session while the
panel is hidden; pairing and failure states always shut down.
The Settings page and remembered-phone recovery states expose a confirmed
**Start over** action. It stops the current trusted session, forgets the local
device identity, preserves user preferences, and immediately opens a fresh QR
ceremony. This local action does not remove the computer from Android’s Paired
devices list.

The ready panel captures the private `Omarchy Android` V4L2 device through Qt
Multimedia and always releases that QML consumer when the panel closes. Its
focused input surface maps aspect-fit pointer coordinates and keyboard intent
into versioned helper commands; the helper validates them and runs targeted
Android `input` commands through its fakeable ADB boundary. Production uses
`/dev/video42` by default; `OMARCHY_ANDROID_V4L2_SINK` overrides the private
sink path.
Opening a ready panel, or reaching Ready after reconnection, automatically
focuses this input surface so keyboard control works without an extra click.

Focused semantic action routing uses the bundled Android 16 profile through
protocol v7. **Close current window** maps to Android Home, and **Open browser**
uses a package-free standard Android browser intent. An optional user-owned
Hyprland loader recognizes the exact typed global panel-toggle declaration,
supported typed Omarchy browser declarations, and verified opaque closures
returned by `hl.dsp.window.close()` after the loader is installed. A typed
intent table is eligible only when `omarchy` is its sole key; declarations with
extra fields remain unchanged. Browser and close routing preserve their
documented desktop fallbacks; panel toggle directly invokes the global plugin
lifecycle without a fallback. The loader never reads or rewrites binding files.
Unavailable, removed, and unknown semantic IDs remain unhandled; arbitrary
functions, ambiguous overrides, desktop chords, and per-device action profiles
are not inferred.

The ready view includes Back, Home, and recent-apps controls plus an inline
Settings page. A chain-link toolbar button and the Settings toggle control the
same persisted keep-connected value. Preview scale accepts 50% through 150%
and defaults to 100%. The embedded viewport follows Qt Multimedia's live
decoded-frame aspect ratio, fills the panel width inside the current Omarchy
popup gutter at 100%, and scales both dimensions uniformly while remaining
bounded by the active output. `PreserveAspectFit` protects frame transitions
and rotation without cropping. Video quality selects a scrcpy profile and
restarts only the active mirroring session; trusted pairing and other
preferences remain intact. Preferences are stored privately beside the
remembered-device record.

Settings is keyboard navigable. Opening it focuses the Back control; Tab and
Shift+Tab traverse its controls, while Escape closes an open selector or
confirmation before returning from Settings to the focused phone view.

The current Android 16 hardware baseline is proven on the supported surface.
The development machine rendered synthetic 360×640 playback at 30 fps and
recovered cleanly across stop/restart with `v4l2loopback` 0.15.4. A physical
CPH2719 running OxygenOS 16 / Android 16 proved real 1080×2392 QML playback,
session and capture restart, pointer input, Back, Home, recent apps, typed
input, focused semantic routing, fail-closed desktop fallback, and lifecycle
recovery. QR pairing, six-digit fallback, and cancel/retry had already passed
on the same platform. This evidence completes the current compatibility slice,
not the full V1 acceptance contract.

Other Android versions remain unsupported until they receive explicit emulator
and physical-device evidence. The project does not install or load system
dependencies.

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
install -Dm755 scripts/omarchy-android-action \
  "$HOME/.local/bin/omarchy-android-action"
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

### Optional semantic binding integration

One opt-in loader routes the exact typed global panel-toggle declaration,
supported typed browser declarations, and recognized `hl.dsp.window.close()`
factory results without per-chord overrides. Add this line to
`~/.config/hypr/hyprland.lua` after the bootstrap `dofile(...)` and
before `require("default.hypr.omarchy")`:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/ollie.android/integrations/hyprland.lua")
```

To migrate an existing direct panel-toggle command, keep the user-owned chord
and any binding options, and replace only its command action with this exact
typed declaration:

```lua
o.bind("SUPER + ALT + A", "Toggle Android panel", { omarchy = "toggle-android-panel" })
```

The declaration directly invokes `omarchy-shell ollie.android toggle`, while
preserving the chosen chord and options. It does not depend on phone focus and
has no desktop fallback because toggle is the global panel lifecycle action.
Only a table whose single key is this supported `omarchy` declaration is
recognized; near matches, tables with extra fields, and unsupported
declarations remain untouched. Browser and close behavior remain as documented
below.

The loader wraps the close factory before defaults load and recognizes only
the exact opaque closures that factory returns. This covers active custom
close-window declarations only when they are constructed through
`hl.dsp.window.close()` after the loader is installed. It also intercepts
allowlisted, typed Omarchy browser declarations while Hyprland evaluates
them. It does not read or rewrite binding files, inspect labels, infer intent
from chords or shell strings, or treat arbitrary functions and ambiguous
overrides as semantic actions. The stock browser bindings, `SUPER + SHIFT + B`
and `SUPER + SHIFT + RETURN`, are supported; unsupported arbitrary overrides
remain unchanged.

Hyprland reloads the user configuration automatically. Validate it with
`hyprctl reload` followed by `hyprctl configerrors`. While the ready, visible,
enabled phone preview owns focus, a recognized mapping runs its Android action.
Protocol-v7 semantic attempts carry an absolute expiry 2 seconds after dispatch;
IPC is bounded to 3 seconds, and the helper rejects deadlines more than 5
seconds ahead. Semantic ADB work is capped at 750 ms. On expiry, the helper
kills and reaps that work before an unhandled result permits desktop fallback,
so the phone cannot act after fallback. Close routing additionally has a
7-second outer execution guard and checks for its correlated result at most
160 times at 50 ms intervals.

If Android rejects or cannot handle the action, the helper fails, or the request
expires, browser routing invokes its direct packaged command fallback exactly
once; close routing preserves the exact original Lua closure and asynchronously
dispatches it once through `hl.dispatch`. Remove the one `dofile` line to
disable semantic binding integration.

## Remove

Disable the widget before removing files:

```bash
omarchy plugin disable ollie.android
rm \"$HOME/.config/omarchy/plugins/ollie.android\"
rm -f \"$HOME/.local/bin/omarchy-android-helper\"
rm -f "$HOME/.local/bin/omarchy-android-action"
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
