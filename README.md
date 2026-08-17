# Omarchy Android

Omarchy Android is an Omarchy bar-widget plugin for pairing and controlling one
Android phone over Wireless debugging. It presents an interactive phone view in
the Omarchy bar panel, uses unmodified scrcpy for video, and sends validated
input through a local Rust helper.

> [!IMPORTANT]
> This is a source-stage project, not a published Omarchy Marketplace release.
> Android 16 is the only supported target, and the complete V1 acceptance matrix
> is not finished. See [Project status](#project-status) before installing it on
> a machine or phone you rely on.

## What it does

- Opens from one Omarchy bar icon and controls one remembered phone.
- Starts with Android-compatible QR pairing and offers a discovered six-digit
  pairing fallback.
- Resolves a remembered phone again by its mDNS service identity instead of
  storing its address.
- Renders scrcpy video from a private V4L2 loopback device inside QML.
- Supports aspect-fit pointer input, ordinary key and text input, and Back,
  Home, and recent-apps quick actions.
- Optionally routes reviewed Omarchy semantic actions to the focused phone.

It does not install an Android companion app, replace scrcpy, manage multiple
phones, read or rewrite the user's binding files, or silently change system
configuration.

## Requirements

The supported runtime is Omarchy with its current Quickshell bar-plugin runtime
and an Android 16 phone on the same trusted local network. Enable **Wireless
debugging** on the phone before pairing.

Host runtime dependencies:

- `android-tools`, providing `adb`;
- `avahi`, providing `avahi-browse` and the Avahi daemon;
- `scrcpy`;
- `qt6-multimedia`;
- `v4l2loopback-dkms` and headers matching the running kernel;
- a private V4L2 loopback device at `/dev/video42`, labelled `Omarchy Android`.

Rust and Cargo are required only to build the helper from this repository.
`lua`, the Qt 6 command-line tools, and the Omarchy source tree are additionally
required for the complete developer check.

### Approve the V4L2 system changes first

> [!CAUTION]
> Package installation, enabling Avahi, loading a DKMS-backed kernel module, and
> making that module persistent are host-wide changes. This repository does none
> of them. Review the packages and obtain the machine owner's explicit approval
> before running the following Omarchy commands.

```bash
omarchy pkg add android-tools avahi scrcpy qt6-multimedia v4l2loopback-dkms
sudo systemctl enable --now avahi-daemon.service
sudo modprobe v4l2loopback devices=1 video_nr=42 card_label="Omarchy Android" exclusive_caps=1
```

The module load lasts until reboot. The plugin does not write `modules-load.d`
or `modprobe.d` configuration. If `v4l2-ctl` is already available, inspect the
approved device with:

```bash
v4l2-ctl --list-devices
```

The output must associate `Omarchy Android` with `/dev/video42`. The helper can
use another private sink path when `OMARCHY_ANDROID_V4L2_SINK` is present in the
environment inherited by `omarchy-shell`, but QML still selects the camera by
the exact `Omarchy Android` label.

## Installation

### Normal user installation

There is no evidence-backed normal installation command yet. The project has no
published Marketplace listing, release binary, or repository URL recorded in
this checkout. In particular, a usable `omarchy plugin add` command cannot be
documented without inventing a source URL, and Omarchy does not build or install
the separate Rust helper on this project's behalf.

Normal users should wait for a release that supplies both a public plugin source
and a matching helper installation procedure. The commands below deliberately
remain in the developer workflow; they create a live symlink to the checkout.

### Developer or source-evaluation setup

Plugins execute unsandboxed inside the long-running `omarchy-shell` process.
Review this repository and its updates before enabling it. The helper is a child
process with access to ADB, Avahi, scrcpy, the private V4L2 device, and the
plugin's private state directory.

From a clean checkout, after approving and preparing the dependencies:

```bash
cargo build --release --manifest-path helper/Cargo.toml
install -Dm755 helper/target/release/omarchy-android-helper \
  "$HOME/.local/bin/omarchy-android-helper"
install -Dm755 scripts/omarchy-android-action \
  "$HOME/.local/bin/omarchy-android-action"
mkdir -p "$HOME/.config/omarchy/plugins"
ln -s "$PWD" "$HOME/.config/omarchy/plugins/ollie.android"
omarchy-shell shell rescanPlugins
omarchy plugin enable ollie.android
```

`~/.local/bin` must be on the `PATH` inherited by `omarchy-shell`. The symlink is
intentional for development: saving QML in the checkout reloads the plugin.
Enabling the plugin adds its single widget through Omarchy's supported plugin
command; it does not overwrite Hyprland configuration.

## Pair a phone

1. Activate the **Omarchy Android** icon in the bar. An unpaired panel prepares
   and immediately displays a fresh QR code.
2. On Android, open **Wireless debugging**, choose **Pair device with QR code**,
   and scan the panel.
3. Keep Wireless debugging open while Avahi discovers the requested temporary
   pairing service and the helper completes ADB pairing and connection.
4. When the phone view appears, click or focus the preview to send pointer,
   ordinary keyboard, and text input to Android.

The QR has a visible countdown and refreshes automatically while the panel
remains open. Closing the panel cancels an active pairing ceremony and removes
its temporary material.

### Six-digit fallback

Select **Pair by code**, request the six-digit code from Android's Wireless
debugging screen, and enter only that code in the panel. The current UI still
depends on Avahi discovery for the temporary endpoint. It does **not** implement
the specification's address-and-port fallback when mDNS is unavailable; that is
a remaining V1 acceptance item.

Do not paste a pairing code, QR payload, discovered endpoint, or complete ADB
output into a bug report or persistent diagnostic file.

### Reconnect or replace the phone

After successful pairing, opening the panel automatically resolves the remembered
`_adb-tls-connect._tcp` service again. If the session ends or the phone is
offline, restore the same trusted Wi-Fi and Wireless debugging, then select
**Reconnect**.

Use **Settings > Start over** to replace the remembered phone. After
confirmation it stops pending and active work, forgets the local service
identity, preserves global preferences, and starts a fresh QR ceremony. It does
not remove the computer from Android's **Paired devices** list; revoke it on the
phone separately if that is required.

## Operate the panel

The bar icon opens or closes the anchored panel. A ready panel focuses the phone
preview automatically, including after reconnection. The preview supports taps,
swipes, named Android keys, and ordinary text; Ctrl, Alt, Meta/Super combinations,
key release ordering, and clipboard transport are not supported V1 controls.

The toolbar has three configurable quick-action slots, a chain-link
**Keep connected** control, and Settings. Closing always releases QML capture,
focus, and input:

- With **Keep phone connected** off, close also stops the active helper/scrcpy
  session. Reopening resolves the phone and starts a new session.
- With it on, close may retain only an already trusted ready or session-starting
  connection. Pairing, disconnected, and failure states are never retained.

### Settings

All settings are private global preferences, not per-device profiles. They
survive **Start over**.

| Setting | Default | Behavior |
| --- | --- | --- |
| **Keep phone connected** | Off | Retains an eligible trusted session while the panel is hidden. |
| **Android-mode shortcuts** | Off | Enables the optional configured semantic routes only while the complete focused-phone predicate holds. |
| **Command passthrough** | Off | With Android-mode shortcuts enabled and the phone eligible, off inhibits unconfigured bindings; on lets them continue to Omarchy. It does not disable configured Android routes. |
| **Preview scale** | 100% | Changes the embedded view from 50% through 150% in five-point steps without cropping. |
| **Quality** | High | Selects Low, Medium, or High; changing it restarts only an active mirroring session. |
| **Quick actions** | Back, Home, Recent apps | Assigns any of those three actions independently to each toolbar slot. |

Settings is keyboard navigable. Tab and Shift+Tab move through controls. Escape
first closes an open selector or confirmation, then returns to the focused phone
view.

## Optional semantic-action integration

This integration is opt-in. The plugin never scans chords or binding files, and
upgrades never rewrite the user's configuration. Copy the example only if the
user-owned file does not already exist:

```bash
test -e "$HOME/.config/hypr/omarchy-android.lua" || \
  install -m644 integrations/config.example.lua \
    "$HOME/.config/hypr/omarchy-android.lua"
```

Load and configure the wrapper after Omarchy's bootstrap but before
`require("default.hypr.omarchy")` registers default bindings:

```lua
local android = dofile(
  os.getenv("HOME") .. "/.config/omarchy/plugins/ollie.android/integrations/hyprland.lua"
)
android.configure(require("hypr.omarchy-android"))
```

After checking the user's active bindings for a conflict, the user may add this
exact typed declaration wherever their ordinary `o.bind` declarations belong:

```lua
o.bind("SUPER + ALT + A", "Toggle Android panel", { omarchy = "toggle-android-panel" })
```

The loader preserves the user-owned chord, description, and options and directly
invokes `omarchy-shell ollie.android toggle`. This global lifecycle action is
independent of phone focus, receives `dont_inhibit`, and has no fallback. Only
the exact structured `omarchy` value matches; near matches, unsupported tables,
and declarations with extra fields remain untouched.

After Omarchy defaults and ordinary user bindings have loaded, install any
Android-only custom bindings from the user configuration:

```lua
android.install_custom_bindings()
```

The complete strict example is
[`integrations/config.example.lua`](integrations/config.example.lua). Its
`routes` table is the complete enabled route set; removing a route restores that
source's ordinary behavior. Unknown fields, sources, targets, target shapes, or
invalid package names reject the configuration atomically.

Packaged source mappings and targets are defined in
[`integrations/action-catalog.lua`](integrations/action-catalog.lua). The example
enables:

| Omarchy source | Android target | Focus/fallback behavior |
| --- | --- | --- |
| `omarchy.android.panel.toggle` | `android.panel.toggle` | Global panel lifecycle; no phone focus and no fallback. |
| `omarchy.browser` | `android.browser.default` | Uses Android's package-free standard browser intent when the phone accepts the attempt. |
| `omarchy.window.close` | `android.navigate.home` | Goes Home on Android; it does not claim to close the Android app. |

The loader recognizes supported typed Omarchy declarations only when `omarchy`
is the table's sole key, plus the verified opaque closure returned by
`hl.dsp.window.close()`. It never guesses from a chord, label, shell string, or
arbitrary function.

With **Android-mode shortcuts** enabled, a focused, visible, input-enabled ready
preview gets first refusal for configured phone routes. If QML refuses before
dispatch, the original browser command or close closure runs once. Once QML
accepts an Android attempt, Android owns it: a later rejection, disconnect,
unhandled backend result, mismatch, or timeout is consumed and does not duplicate
the action on the desktop. Quick actions, pointer input, named key input, and
text input remain independent of both shortcut settings.

The current helper/QML contract is protocol v10; the bundled action manifest in
[`actions.json`](actions.json) is schema version 3. Semantic attempts carry an
absolute two-second expiry, use bounded IPC, and kill and reap expired Android
work before returning a consumed result.

Saving the required user module is watched by Hyprland's wrapped `require`.
After changing it, inspect errors with:

```bash
hyprctl configerrors
```

Remove the loader/configure lines and `android.install_custom_bindings()` to
disable the integration. The user-owned configuration file may remain.

## Security and privacy

- The plugin QML is unsandboxed in `omarchy-shell`; only enable reviewed code.
- Pairing secrets, six-digit codes, raw connection endpoints, full ADB output,
  and scrcpy output are neither persisted nor exposed by the helper protocol.
- Temporary QR SVGs live in the private runtime directory and are removed with
  their ceremony. The panel-launched helper's acceptance log contains only the
  same fixed, redacted protocol events, never command input or subprocess output.
- The remembered-device record contains only one validated mDNS connection
  service name. Preferences and that record live beneath
  `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-android` with private
  permissions.
- Reconnection resolves a fresh endpoint in memory. A stored address is never
  reused.
- The helper passes ADB arguments as separated process arguments, discards
  subprocess output, and runs scrcpy with control disabled. QML-originated input
  uses a separate validated ADB adapter.
- There is no cloud service, telemetry, open-ended app inventory, clipboard
  bridge, or accepted per-device action profile.

Treat Wireless debugging as trusted-network access. Disable it on Android when
it is not needed, and manage the computer's authorization from Android's Paired
devices screen.

## Troubleshooting

- **Widget or helper unavailable:** For a source setup, confirm the symlink is at
  `~/.config/omarchy/plugins/ollie.android`, the two installed executables are in
  `~/.local/bin`, that directory is on the shell's inherited `PATH`, and then
  rescan and enable the plugin with the installation commands above.
- **Local dependency unavailable:** Confirm `adb`, `avahi-browse`, and `scrcpy`
  are installed and available to `omarchy-shell`; confirm Avahi is running.
  Recheck the separately approved V4L2 device and Qt Multimedia package.
- **Phone video device unavailable or black preview:** Confirm the loopback
  device still has the `Omarchy Android` label, is writable by the user, and is
  not held by a stale producer. Close and reopen the panel to start fresh QML and
  scrcpy consumers. Do not unload the module while another loopback user needs it.
- **QR or code pairing fails:** Keep Wireless debugging open, keep both devices
  on the same trusted network, and allow mDNS traffic. The current six-digit
  path cannot bypass unavailable Avahi with a manual endpoint.
- **Authorization required:** Unlock the phone, approve its Wireless debugging
  prompt, and retry. If necessary, connect the unlocked phone over USB only long
  enough to review/restore debugging authorization through normal Android/ADB
  tooling; the plugin will not automate or change USB configuration. Disconnect
  USB, leave Wireless debugging enabled, and select **Reconnect**.
- **Remembered phone cannot reconnect:** Restore the original trusted Wi-Fi and
  Wireless debugging first. If the phone was replaced or its pairing was reset,
  use **Start over** rather than editing the private state file.
- **Semantic route does nothing:** Check `hyprctl configerrors`, confirm the
  loader order and exact source/target IDs, enable **Android-mode shortcuts**,
  close Settings, and focus the ready phone preview. An accepted but unhandled
  attempt intentionally does not run desktop fallback.

## Remove a developer/source installation

Disable the widget before removing its live checkout link and installed helper
commands:

```bash
omarchy plugin disable ollie.android
rm "$HOME/.config/omarchy/plugins/ollie.android"
rm -f "$HOME/.local/bin/omarchy-android-helper"
rm -f "$HOME/.local/bin/omarchy-android-action"
```

Private device identity and preferences remain under
`${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-android`. Remove that directory
only when intentionally forgetting the phone and every setting. System packages,
Avahi enablement, kernel headers, module persistence, and the loaded loopback
module are shared host state and are deliberately not changed by plugin removal.

## Verification

### Automated developer check

From the repository root, run:

```bash
./scripts/check.sh
```

The script validates the manifest, exercises the shell dispatcher and Lua
integration, lints QML through a temporary Omarchy import map, runs Qt Quick
Tests, and runs Rust format, Clippy-with-warnings-denied, and test checks. Its
automated tests use fake ADB, scrcpy, and mDNS boundaries; they do not pair,
connect to, or alter a real phone.

### Real-phone acceptance

A release that changes pairing, video, input, or lifecycle still requires a
manual run on the named physical phone. Do not automate that run against an
unattended device, and do not save complete ADB output. Verify through visible
panel and phone behavior:

1. QR pairing, discovered six-digit fallback, cancellation, retry, and secret
   redaction.
2. Reconnect, both **Keep phone connected** close paths, and **Start over**.
3. Live V4L2 video, rotation/aspect behavior, pointer input, ordinary text, and
   Back/Home/recent-apps.
4. Focus-safe semantic routing, desktop behavior before QML acceptance, consumed
   behavior after acceptance, immediate shortcut disable, and global panel
   toggle.
5. Dependency, authorization, network, and recovery states without exposing an
   endpoint, code, secret, or complete subprocess output.

An Android emulator is useful for ready-surface geometry, video, input, and
session lifecycle. It is not evidence for QR/mDNS/vendor/real-Wi-Fi acceptance;
those checks require a physical phone. Do not describe emulator QR pairing as a
supported workflow.

## Project status

The current evidence is specific to a CPH2719 running OxygenOS 16 / Android 16.
It includes QR and six-digit pairing with cancel/retry, Avahi connection-service
discovery, 1080×2392 QML playback, session/capture restart, pointer and ordinary
text input, Back/Home/recent-apps, preference migrations, focused shortcut
routing, shortcut inhibition, and the global panel toggle. A browser backend
attempt in the Stage 7 run returned unhandled and was observed using the then
applicable desktop fallback; it is not evidence that every Android action is
handled, and the current accepted-attempt ownership rule supersedes that earlier
fallback behavior.

The complete V1 acceptance contract is still open. In particular, the manual
address-and-port pairing fallback, broader recovery acceptance, modifier/layout
coverage, clipboard, provisional Actions UI, per-device profiles, and Android
14/15 support are not shipped or claimed. Marketplace publication is a later
release step.

[`SPEC.md`](SPEC.md) is the V1 behavior contract and contains the complete
verified-evidence record. [`PLAN.md`](PLAN.md) is the decision log.
[`AGENTS.md`](AGENTS.md) defines the implementation and verification boundaries
for contributors.

## Repository layout

- `BarWidget.qml` and `Panel.qml` define the Omarchy bar surface and anchored
  panel.
- `qml/` owns panel components and local UI state.
- `helper/` contains the Rust protocol, persistence, ADB, Avahi, and scrcpy
  boundaries.
- `actions.json` is the classified semantic-action contract.
- `integrations/` contains the opt-in Hyprland loader and user configuration
  example.
- `scripts/omarchy-android-action` is the bounded semantic dispatcher.
- `scripts/check.sh` is the non-interactive developer verification entry point.
- `tests/` and `helper/tests/` cover QML, Lua, shell, and Rust behavior without a
  real phone.
