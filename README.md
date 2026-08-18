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
- Provides a dedicated `omarchy-android` key-binding context while an
  interactive phone panel owns Android-mode shortcuts.

It does not install an Android companion app, replace scrcpy, manage multiple
phones, translate user bindings, or silently change system configuration. Its
configurator manages only one exact loader block and creates the user-owned
phone-binding file only when that file is absent.

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
sudo modprobe v4l2loopback devices=1 video_nr=42 card_label="Omarchy Android" exclusive_caps=0
```

`exclusive_caps=0` is required for the long-running Quickshell process. The
shell can initialize Qt Multimedia before scrcpy starts; output-only
advertisement hides the loopback from that process for the rest of its
lifetime.

The module load lasts until reboot. The plugin does not write `modules-load.d`
or `modprobe.d` configuration. If `v4l2-ctl` is already available, inspect the
approved device with:

```bash
v4l2-ctl --list-devices
```

The output must associate `Omarchy Android` with `/dev/video42`. This fixed
path-and-label pair is the capture endpoint contract: the helper accepts only
that direct character device with matching sysfs identity, and QML accepts
exactly one camera whose ID is `/dev/video42` and label is `Omarchy Android`.
Remove any `OMARCHY_ANDROID_V4L2_SINK` override from the environment before
upgrading; alternate sink paths are no longer supported.

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
mkdir -p "$HOME/.config/omarchy/plugins"
ln -s "$PWD" "$HOME/.config/omarchy/plugins/ollie.android"
scripts/configure-phone-bindings install
omarchy-shell shell rescanPlugins
omarchy plugin enable ollie.android
```

`~/.local/bin` must be on the `PATH` inherited by `omarchy-shell`. The symlink is
intentional for development: saving QML in the checkout reloads the plugin.
The configurator installs the user-owned phone bindings once and adds only its
documented loader block. Enabling the plugin adds its single widget through
Omarchy's supported plugin command.

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
| **Android-mode shortcuts** | On | Activates the configured `omarchy-android` submap only while the panel is interactive. |
| **Preview scale** | 100% | Changes the embedded view from 50% through 150% in five-point steps without cropping. |
| **Quality** | High | Selects Low, Medium, or High; changing it restarts only an active mirroring session. |
| **Quick actions** | Back, Home, Recent apps | Assigns any of those three actions independently to each toolbar slot. |

Settings is keyboard navigable. Tab and Shift+Tab move through controls. Escape
first closes an open selector or confirmation, then returns to the focused phone
view.

## Phone-mode key bindings

Run the repository configurator after linking the plugin:

```bash
scripts/configure-phone-bindings install
```

It uses `${XDG_CONFIG_HOME:-$HOME/.config}` for Hyprland configuration. On the
first install it copies
[`integrations/omarchy-android.lua.example`](integrations/omarchy-android.lua.example)
to `hypr/omarchy-android.lua`. An existing file is always left byte-for-byte
unchanged. It also adds only this exact block to `hypr/bindings.lua` when the
block is absent:

```lua
-- Omarchy Android plugin loader (managed)
require("hypr.omarchy-android")
```

The user module loads the plugin-owned
[`integrations/phone-bindings.lua`](integrations/phone-bindings.lua) API and
defines exactly one `omarchy-android` submap. Saving the module follows
Omarchy's normal watched `require` reload path. The plugin does not scan,
translate, infer, or rewrite binding declarations.

The same user module owns optional scrcpy arguments. Declare them once before
the submap and keep the commit as the final statement:

```lua
android.configure({
  scrcpyArgs = {
    "--keep-active",
    "--turn-screen-off",
    "--stay-awake",
  },
})

android.define_submap("omarchy-android", function()
  -- bindings
end)

android.commitConfiguration()
```

Each entry is one argument, not a shell command. The API rejects malformed,
transport-, display-, audio-, control-, and cleanup-changing options. A valid
commit is stored privately and restarts only an active phone session. When
`--turn-screen-off` is configured, the first session renders with the physical
display still on; only after the panel renders its first valid frame does the
plugin restart scrcpy with screen-off enabled. Removing the option causes one
restart that restores normal scrcpy cleanup behavior. Android lock-screen and
device-policy behavior remain unchanged.

Phone mode is active only when the panel is open, **Android-mode shortcuts** is
enabled, and the canonical application state is `interactive`. In that mode,
configured chords belong only to Android. An unconfigured desktop chord is
inert rather than falling through to its desktop action. Closing the panel,
disabling Android-mode shortcuts, losing `interactive`, or restarting the
helper resets the submap immediately. Outside phone mode, ordinary desktop
bindings behave normally.

The installed template enables only these four bindings:

| Chord | Description | Target |
| --- | --- | --- |
| `SUPER + ESCAPE` | Close Android panel | `android.close_panel` |
| `SUPER + SHIFT + RETURN` | Browser | `android.browser.default` |
| `SUPER + SHIFT + B` | Browser | `android.browser.default` |
| `SUPER + W` | Close current window | `android.navigate.home` |

The close callback synchronously resets Hyprland before requesting panel close,
so a delayed close acknowledgement cannot strand keyboard ownership. The Home
target leaves the current Android app; it does not claim to terminate it.
Device- or package-dependent examples remain commented out.

User additions use the same direct API:

```lua
android.bind("CTRL + ALT + SHIFT + P", "My Android app", {
  type = "android.app.launch",
  package = "com.example.app",
})
```

Supported targets are `android.browser.default`, `android.navigate.home`,
`android.navigate.back`, `android.recent-apps`, and a typed
`android.app.launch` object with a validated package name. Arbitrary ADB or
shell commands are not accepted.

Each target dispatch sends one base64url-encoded JSON envelope to
`omarchy-shell ollie.android phoneTarget`. The envelope has a unique
`requestId`, the direct typed `target`, and a two-second absolute deadline. QML
accepts it only in the interactive state, adds the current helper epoch and
session generation, and sends protocol v11 to Rust. Stale, missing, invalid,
failed, or timed-out attempts are consumed and never run a desktop fallback.

After editing the user module, inspect normal Lua reload errors with:

```bash
hyprctl configerrors
```

To remove the integration loader without deleting the user-owned module, run:

```bash
scripts/configure-phone-bindings uninstall
```

Install and uninstall are idempotent. Uninstall removes only the exact managed
loader block and preserves all other Hyprland configuration bytes.

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
  `~/.config/omarchy/plugins/ollie.android`, the helper is installed in
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
- **Phone shortcut does nothing:** Check `hyprctl configerrors`, confirm the
  managed loader block and user module are present, enable **Android-mode
  shortcuts**, close Settings, and wait for the phone state to become
  interactive. Target failures are consumed and never invoke a desktop action.

## Remove a developer/source installation

Disable the widget and remove the managed Hyprland loader before deleting the
live checkout link and installed helper:

```bash
omarchy plugin disable ollie.android
scripts/configure-phone-bindings uninstall
rm "$HOME/.config/omarchy/plugins/ollie.android"
rm -f "$HOME/.local/bin/omarchy-android-helper"
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

The script validates the manifest, exercises the phone-binding configurator and
Lua API, checks cross-language target and protocol contracts, runs the tested
ast-grep ownership rules, lints QML through a temporary Omarchy import map,
runs Qt Quick Tests, and runs Rust format, Clippy-with-warnings-denied, and
nextest checks. It requires the Omarchy Qt 6 environment, Lua, `ast-grep`, and
`cargo-nextest`. Its automated tests use fake ADB, scrcpy, and mDNS boundaries;
they do not pair, connect to, or alter a real phone.

Run the slower focused coverage and online dependency gates separately:

```bash
./scripts/check-coverage.sh
./scripts/check-supply-chain.sh
```

Coverage requires `cargo-llvm-cov`, `llvm-cov`, `llvm-profdata`, and `jq`. It
enforces measured line-coverage floors for phone-target actions, input
validation, pairing, protocol, persistence, preferences, and runtime deadline
contracts. The supply-chain gate requires `cargo-deny` and
`cargo-audit`; it denies known advisories, yanked crates, wildcard dependencies,
unapproved licenses, and unknown registries or Git sources. These network-backed
checks are intentionally separate from the deterministic local gate.

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
4. Phone-submap entry and reset, mandatory reset-before-close, direct target
   dispatch without desktop fallback, Android-mode disable, and ordinary
   unmodified typing while phone mode is active.
5. Dependency, authorization, network, and recovery states without exposing an
   endpoint, code, secret, or complete subprocess output.

An Android emulator is useful for ready-surface geometry, video, input, and
session lifecycle. It is not evidence for QR/mDNS/vendor/real-Wi-Fi acceptance;
those checks require a physical phone. Do not describe emulator QR pairing as a
supported workflow.

## Project status

The current physical-device evidence is specific to a CPH2719 running OxygenOS
16 / Android 16. It includes QR and six-digit pairing with cancel/retry, Avahi
connection-service discovery, 1080×2392 QML playback, session/capture restart,
pointer and ordinary text input, Back/Home/recent-apps, and preference
persistence. Phone-submap ownership and the Browser and Home target adapters
have automated contract coverage; they still require the real-phone acceptance
run above before release or expansion of the enabled defaults.

The complete V1 acceptance contract is still open. In particular, the manual
address-and-port pairing fallback, broader recovery acceptance, modifier/layout
coverage, clipboard, provisional Actions UI, per-device profiles, and Android
14/15 support are not shipped or claimed. Marketplace publication is a later
release step.


## Repository layout

- `BarWidget.qml` and `Panel.qml` define the Omarchy bar surface and anchored
  panel.
- `qml/` owns panel components and local UI state.
- `helper/` contains the Rust protocol, persistence, ADB, Avahi, and scrcpy
  boundaries.
- `integrations/phone-bindings.lua` defines the plugin-owned phone-submap API,
  and `integrations/omarchy-android.lua.example` is copied once as user-owned
  configuration.
- `scripts/configure-phone-bindings` installs or removes only the managed
  Hyprland loader block.
- `scripts/check.sh` is the non-interactive developer verification entry point.
- `tests/` and `helper/tests/` cover QML, Lua, shell, and Rust behavior without a
  real phone.
