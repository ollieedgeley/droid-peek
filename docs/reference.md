# Droid Peek reference

Use this page to look up canonical names, paths, bindings, settings, and limits.
For procedures, see [Use and configure](how-to-use-and-configure.md).

## Identity and paths

| What | Value |
| --- | --- |
| Product | Droid Peek |
| Repository | `ollieedgeley/droid-peek` |
| Plugin id and IPC name | `ollieedgeley.droidpeek` |
| Checkout | `~/.config/omarchy/plugins/ollieedgeley.droidpeek/` |
| Helper | `~/.local/bin/droid-peek-helper` |
| User Lua | `~/.config/hypr/droid-peek.lua` |
| Internal submap | `droid-peek` |
| V4L2 device | `/dev/video42`, label `Droid Peek` |
| State | `${XDG_STATE_HOME:-$HOME/.local/state}/droid-peek` |

`manifest.json` is the repository release version. The helper package version,
`qml/BuildInfo.qml`, and `integrations/build-info.lua` must agree with it.

## Host prerequisites

Setup enforces x86_64, the stock Arch `linux` kernel with matching headers,
DKMS v4l2loopback, and an active Omarchy-provided Avahi service. The Android
device must be reachable on the same local network with Wireless debugging
enabled.

Install the visible dependencies with:

```bash
omarchy pkg add scrcpy qt6-multimedia v4l2loopback-dkms linux-headers
```

Avahi is part of Omarchy. `scrcpy` pulls in `android-tools`, and
`v4l2loopback-dkms` pulls in `dkms`. Setup installs no package or service.

## Setup interfaces

```text
scripts/setup-droid-peek [--dry-run] [--yes]
scripts/cleanup-droid-peek [--dry-run] [--yes]
  [--remove-helper] [--remove-v4l2] [--remove-user-config] [--remove-state]
```

`--dry-run` prints a plan without changes. `--yes` makes a real invocation
non-interactive. Setup still performs every check. Cleanup with `--yes` and no
`--remove-*` option removes only the managed loader.

`DROID_PEEK_HELPER_ASSET_DIR` selects a local directory instead of GitHub
release URLs. It must contain the exact versioned x86_64 helper and a
single-entry `SHA256SUMS`. Checksum and helper-version validation still apply;
the helper is never selected from `PATH`.

## Panel and Android mode

The Droid Peek bar icon opens or closes the panel. Android mode is active only
while the panel is open, **Android-mode shortcuts** is enabled, and the session
is interactive. Under those three conditions, `Super+Alt+A` closes the panel.

## Default Android-mode bindings

| Chord | Label | Target |
| --- | --- | --- |
| Super+Alt+A | Close Android panel | `android.close_panel` |
| Alt+Tab | Recent apps | `android.recent-apps` |
| Super+W | Home | `android.navigate.home` |
| Super+C | Copy | `android.keyevent` `copy` |
| Super+V | Paste | `android.keyevent` `paste` |
| Super+X | Cut | `android.keyevent` `cut` |
| XF86AudioRaiseVolume | Volume up | `android.keyevent` `volume-up` |
| XF86AudioLowerVolume | Volume down | `android.keyevent` `volume-down` |
| XF86AudioMute | Mute | `android.keyevent` `volume-mute` |
| XF86AudioNext / Alt+XF86AudioPlay | Next track | `android.keyevent` `media-next` |
| XF86AudioPlay / XF86AudioPause | Play or pause | `android.keyevent` `media-play-pause` |
| XF86AudioPrev / Alt+Shift+XF86AudioPlay | Previous track | `android.keyevent` `media-previous` |

Copy, cut, and paste operate inside Android. There is no desktop clipboard
synchronization.

Allowed targets are `android.close_panel`, `android.navigate.home`,
`android.navigate.back`, `android.recent-apps`, `android.app.launch` with
`package`, `android.component.launch` with `package` and `activity`, and
`android.keyevent` with `key`. Arbitrary shell execution is not allowed.

## Reserved scrcpy arguments

Droid Peek rejects `--serial`, `--select-usb`, `--select-tcpip`, `--tcpip`,
`--video-source`, `--new-display`, `--display`, `--v4l2-sink`, `--no-video`,
`--no-window`, `--window`, `--control`, `--no-control`, `--no-cleanup`,
`--no-power-on`, `--max-size`, `--video-bit-rate`, `--max-fps`, and arguments
starting with `--audio`. `scrcpyArgs` accepts at most 32 strings.

## Settings defaults

| Setting | Default |
| --- | --- |
| Keep device connected | Off |
| Android-mode shortcuts | On |
| Preview scale | 100% (50–150, step 5) |
| Quality | High |
| Quick actions | Back, Home, Recents |

## Managed files

```text
/etc/modules-load.d/droid-peek.conf
/etc/modprobe.d/droid-peek.conf
~/.local/bin/droid-peek-helper
~/.config/hypr/droid-peek.lua          # user-owned after the first copy
~/.config/hypr/bindings.lua            # managed require() block only
```

The loader block is:

```lua
-- Droid Peek plugin loader (managed)
require("hypr.droid-peek")
```

Stable internal files such as `integrations/phone-bindings.lua` retain their
compatibility names; those names are not user-visible device terminology.
