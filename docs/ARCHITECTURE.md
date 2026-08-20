# How Droid Peek works

Droid Peek keeps the phone-control path small and explicit:

1. Android Wireless debugging pairs the phone with ADB.
2. A local Rust helper, `droid-peek-helper`, finds and manages the selected
   phone.
3. Unmodified [scrcpy](https://github.com/Genymobile/scrcpy) mirrors the phone
   into one dedicated Linux V4L2 device.
4. Quickshell renders that device inside the Omarchy panel.
5. Validated input and configured bindings travel only to the active paired
   phone.

## Canonical identity

| Purpose | Value |
| --- | --- |
| Public product name | `Droid Peek` |
| GitHub repository | `ollieedgeley/droid-peek` |
| Plugin manifest id / QML IPC target | `ollieedgeley.droidpeek` |
| Plugin checkout | `~/.config/omarchy/plugins/ollieedgeley.droidpeek/` |
| Hyprland submap | `droid-peek` |
| User-owned Lua module | `~/.config/hypr/droid-peek.lua` |
| Helper executable | `droid-peek-helper` |
| Installed helper path | `~/.local/bin/droid-peek-helper` |
| State and runtime namespace | `droid-peek` |
| V4L2 card label | `Droid Peek` |
| V4L2 device | `/dev/video42` |

The root `manifest.json` is the release-version source of truth. The helper
package version must equal it. Protocol and persisted-state versions are
independent compatibility values. `qml/BuildInfo.qml` exports
`releaseVersion`, and `integrations/build-info.lua` returns
`release_version`. Those generated constants are the sole expected-version
values used for the helper handshake.

Panel and Lua resolve only the deterministic installed path
`~/.local/bin/droid-peek-helper`. A missing, nonzero, malformed, or
mismatched `--version` result prevents the session or configuration commit.

## Surfaces

`BarWidget.qml` and `Panel.qml` define the Omarchy bar surface and anchored
panel. `qml/` owns panel components and local UI state. Plugin QML executes
unsandboxed inside the long-running `omarchy-shell` process.

The helper in `helper/` owns the protocol, persistence, ADB, Avahi, and
scrcpy boundaries. It passes ADB arguments as separated process arguments
and discards subprocess output. scrcpy control is off unless the admitted
`scrcpyArgs` list contains `--keep-active`, `--stay-awake`, or
`--turn-screen-off`; the shipped template includes those flags, so the
default session has control.
QML-originated input uses a separate validated ADB adapter.

`integrations/phone-bindings.lua` defines the plugin-owned phone-submap API.
`integrations/droid-peek.lua.example` is copied once as user-owned
configuration. The user module may declare typed Android actions, key events,
exact app packages, and a reserved-safe `scrcpyArgs` list. It cannot pass
arbitrary ADB shell commands.

## Pairing and reconnection

An unpaired panel prepares and immediately displays a fresh QR code. Android
**Pair device with QR code** is the happy path. **Pair by code** is a
discovered six-digit fallback that still depends on Avahi for the temporary
endpoint; there is no manual address-and-port fallback when mDNS is
unavailable.

The QR has a visible countdown and refreshes automatically while the panel
remains open. Closing the panel cancels an active pairing ceremony and
removes its temporary material.

After successful pairing, opening the panel automatically resolves the
remembered `_adb-tls-connect._tcp` service again. Reconnection resolves a
fresh endpoint in memory. A stored address is never reused. The remembered
device record contains only one validated mDNS connection service name.

## Dedicated video device

Setup creates one named `Droid Peek` V4L2 endpoint at `/dev/video42` with
`exclusive_caps=0`. The helper accepts only that direct character device with
matching sysfs identity, and QML accepts exactly one camera whose ID is
`/dev/video42` and label is `Droid Peek`.

The empty device stays idle between sessions, including after reboot. It does
not process phone video unless Droid Peek is streaming. Opening the
interactive panel starts scrcpy and the QML capture path; closing them
releases the device while retaining the dedicated endpoint.

## Lifecycle

Closing always releases focus and input.

- With **Keep phone connected** off, close also stops the active
  helper/scrcpy session. Reopening resolves the phone and starts a new
  session.
- With it on, close may retain an already trusted ready or session-starting
  connection. Pairing, disconnected, and failure states are never retained. A
  connecting session still releases QML capture until a frame exists.

Panel close and helper failure must leave no scrcpy or guardian process
running.

## Security boundary

The configuration can select typed Android actions, key events, and exact app
packages. It cannot pass arbitrary ADB shell commands. Android still owns its
own authentication, lock screen, and permissions.

- Pairing secrets, six-digit codes, raw connection endpoints, full ADB
  output, and scrcpy output are neither persisted nor exposed by the helper
  protocol.
- Temporary QR SVGs live in the private runtime directory and are removed
  with their ceremony. The panel-launched helper's acceptance log contains
  only the same fixed, redacted protocol events, never command input or
  subprocess output.
- Preferences and the remembered-device record live beneath
  `${XDG_STATE_HOME:-$HOME/.local/state}/droid-peek` with private
  permissions.
- There is no cloud service, telemetry, open-ended app inventory, clipboard
  bridge, or accepted per-device action profile.

Treat Wireless debugging as trusted-network access. Disable it on Android
when it is not needed, and manage the computer's authorization from Android's
Paired devices screen.

## Repository layout

- `BarWidget.qml` and `Panel.qml` define the Omarchy bar surface and anchored
  panel.
- `qml/` owns panel components and local UI state.
- `helper/` contains the Rust protocol, persistence, ADB, Avahi, and scrcpy
  boundaries.
- `integrations/phone-bindings.lua` defines the plugin-owned phone-submap
  API, and `integrations/droid-peek.lua.example` is copied once as user-owned
  configuration.
- `scripts/setup-droid-peek` and `scripts/cleanup-droid-peek` are the public
  host setup and cleanup entry points. They own the managed Hyprland loader
  block; `scripts/lib/` is internal.
- `scripts/dev/check.sh` is the non-interactive developer verification entry
  point.
- `tests/` and `helper/tests/` cover QML, Lua, shell, and Rust behavior
  without a real phone.
