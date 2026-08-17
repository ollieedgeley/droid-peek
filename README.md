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
protocol v10. **Close current window** maps to Android Home, and **Open
browser** uses a package-free standard Android browser intent. An optional
user-owned Hyprland loader recognizes the exact typed global panel-toggle
declaration, supported typed Omarchy browser declarations, and verified opaque
closures returned by `hl.dsp.window.close()` after the loader is installed. A
typed intent table is eligible only when `omarchy` is its sole key;
declarations with extra fields remain unchanged. Browser and close routing
preserve their documented desktop fallbacks; panel toggle directly invokes the
global plugin lifecycle without a fallback and bypasses shortcut inhibition so
it can always close the panel. The loader never reads or rewrites binding
files. Unavailable, removed, and unknown semantic IDs remain unhandled;
arbitrary functions, ambiguous overrides, desktop chords, and per-device
action profiles are not inferred.

Settings exposes two global controls. **Android-mode shortcuts** is the master
switch and defaults off. With **Command passthrough** also on, configured typed
Omarchy actions receive semantic first refusal under the complete focused-phone
predicate. With Android mode on and command passthrough off, typed routing is
disabled and the focused panel requests Wayland compositor shortcut inhibition
instead. Closing the panel, opening Settings, or losing phone focus releases
that inhibition. This raw-shortcut mode does not add arbitrary Android modifier
transport: the current input translator does not preserve combinations such as
Super+Enter. Turning the master switch off restores normal desktop handling.
Both controls update before the next dispatch, persist privately as global
preferences, survive **Start over**, and do not disable quick actions, pointer
input, named key input, or text input.

The ready view includes Back, Home, and recent-apps controls plus an inline
Settings page. A chain-link toolbar button and the Settings toggle control the
same persisted keep-connected value. Preview scale accepts 50% through 150%
and defaults to 100%. The embedded viewport follows Qt Multimedia's live
decoded-frame aspect ratio, fills the panel width inside the current Omarchy
popup gutter at 100%, and scales both dimensions uniformly while remaining
bounded by the active output. `PreserveAspectFit` protects frame transitions
and rotation without cropping. Video quality selects a scrcpy profile and
restarts only the active mirroring session; trusted pairing and other
preferences remain intact. Preferences, including both shortcut controls, are
stored privately beside the remembered-device record.

Settings is keyboard navigable. Opening it focuses the Back control; Tab and
Shift+Tab traverse its controls, while Escape closes an open selector or
confirmation before returning from Settings to the focused phone view.

The current Android 16 hardware baseline is proven on the supported surface.
The development machine rendered synthetic 360×640 playback at 30 fps and
recovered cleanly across stop/restart with `v4l2loopback` 0.15.4. A physical
CPH2719 running OxygenOS 16 / Android 16 proved real 1080×2392 QML playback,
session and capture restart, pointer input, Back, Home, recent apps, typed
input, focused semantic routing, fail-closed desktop fallback, and lifecycle
recovery. The Stage 7 run also proved private v3-to-v4 preference migration
with the new switch off, visible Settings control, keyboard persistence to
true without a session restart, and same-cycle focused routing changing from
accepted while enabled to rejected immediately after disabling. A browser
backend attempt returned unhandled and correctly used desktop fallback; this
run does not claim that every Android action was handled. QR pairing,
six-digit fallback, and cancel/retry had already passed on the same platform.
The Stage 8 run then proved private v4-to-v5 migration with command passthrough
off, visible keyboard-operable Settings control, persistence without restarting
the session, and mutually exclusive live routing modes. With passthrough on,
Super+Enter launched Termux on the phone while the desktop Kitty count remained
one. With passthrough off, a focused browser chord produced no semantic request
and left the panel open, while Super+Alt+A still closed it through the global
toggle's inhibition bypass.
This evidence completes the current compatibility slice, not the full V1
acceptance contract.

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

The opt-in Hyprland integration routes reviewed Omarchy actions to Android
without binding behavior to a particular chord. Copy the editable configuration
once; later plugin updates must not overwrite it:

```bash
test -e "$HOME/.config/hypr/omarchy-android.lua" || \
  install -m644 integrations/config.example.lua \
    "$HOME/.config/hypr/omarchy-android.lua"
```

Load and configure the integration after Omarchy's bootstrap but before
`require("default.hypr.omarchy")`:

```lua
local android = dofile(
  os.getenv("HOME") .. "/.config/omarchy/plugins/ollie.android/integrations/hyprland.lua"
)
android.configure(require("hypr.omarchy-android"))
```

After Omarchy defaults and the user's ordinary bindings have loaded, register
any Android-only chords:

```lua
android.install_custom_bindings()
```

The configuration file returns one strict table:

```lua
return {
  routes = {
    ["omarchy.android.panel.toggle"] = "android.panel.toggle",
    ["omarchy.browser"] = "android.browser.default",
    ["omarchy.window.close"] = "android.navigate.home",
  },
  customBindings = {
    {
      keys = "CTRL + ALT + SHIFT + P",
      action = { type = "android.app.launch", package = "com.example.app" },
    },
  },
}
```

`routes` is the complete enabled routing table; there is no second built-in
default mapping table. Remove or comment out a route to preserve that source's
original Omarchy behavior. Change its target to remap it. Unknown fields,
missing `routes`, unknown source or target IDs, and malformed package names stop
configuration with a precise error.
Custom bindings are registered only in the second phase, after normal bindings,
so collision handling remains Omarchy's. They have no desktop fallback because
no pre-existing desktop action owns them.
The routed global panel toggle automatically gains Hyprland's `dont_inhibit`
option without mutating caller-owned binding options. Other routed actions keep
their original options and remain suppressible while raw shortcut inhibition is
active.

The bundled semantic action matrix uses schema version 3; the version bump adds
the structured `android-launch-app` result rather than silently extending
schema version 2.

Available Omarchy source IDs:

| Source ID | Existing Omarchy action |
| --- | --- |
| `omarchy.terminal` | Terminal |
| `omarchy.browser` | Browser |
| `omarchy.browser.private` | Private browser |
| `omarchy.file-manager` | File manager |
| `omarchy.file-manager.cwd` | File manager at current directory |
| `omarchy.editor` | Editor |
| `omarchy.terminal.tmux` | Tmux terminal |
| `omarchy.terminal.herdr` | Herdr terminal |
| `omarchy.spotify` | Spotify |
| `omarchy.signal` | Signal |
| `omarchy.passwords` | Password manager |
| `omarchy.android.panel.toggle` | Android panel toggle |
| `omarchy.window.close` | `hl.dsp.window.close()` |

Available Android target IDs:

| Target ID | Android behavior |
| --- | --- |
| `android.panel.toggle` | Open or close the Android panel |
| `android.browser.default` | Open Android's default browser |
| `android.launcher.search` | Open launcher search; currently unavailable pending capability proof |
| `android.navigate.back` | Android Back |
| `android.navigate.home` | Android Home |
| `android.navigate.recent-apps` | Android recent apps |
| `{ type = "android.app.launch", package = "com.example.app" }` | Launch one validated package |

The example configuration explicitly enables the panel toggle, default-browser,
and close-to-Home routes. Existing bindings retain their exact desktop
dispatcher as fallback. The panel toggle is global and has no fallback.
The loader matches only allowlisted typed Omarchy declarations and
opaque closures returned by `hl.dsp.window.close()`; it never parses chords,
labels, shell strings, or binding files.

The global **Android-mode shortcuts** Settings switch remains the master
control and defaults off. While enabled, a ready, visible, input-enabled phone
preview must own keyboard focus before a focused-phone route can run. Protocol
v9 carries the correlated request ID, absolute expiry, and optional validated
action argument. IPC is bounded to 3 seconds; semantic ADB work is capped at
750 ms and is killed and reaped before desktop fallback. Close routing also has
a 7-second outer guard. Android rejection, disconnect, timeout, protocol
mismatch, or an unhandled action invokes the original fallback exactly once.

Hyprland watches modules loaded through its wrapped `require`, so saving
`~/.config/hypr/omarchy-android.lua` automatically reloads the complete
configuration. Check `hyprctl configerrors` after an edit. Remove the integration
loader/configure lines and the `install_custom_bindings()` call to disable the
integration; the user-owned configuration file may remain.

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
