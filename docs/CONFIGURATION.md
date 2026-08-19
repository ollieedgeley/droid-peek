# Configure Droid Peek

User-owned configuration lives at `~/.config/hypr/droid-peek.lua`. Setup
creates that file from
[`integrations/droid-peek.lua.example`](../integrations/droid-peek.lua.example)
only when it is absent. Later setup and updates may verify that the file
exists; they never rewrite it.

The configurator also adds only this exact block to
`~/.config/hypr/bindings.lua` when the block is absent:

```lua
-- Droid Peek plugin loader (managed)
require("hypr.droid-peek")
```

The user module loads the plugin-owned
[`integrations/phone-bindings.lua`](../integrations/phone-bindings.lua) API
and defines exactly one `droid-peek` submap. Saving the module follows
Omarchy's normal watched `require` reload path. The plugin does not scan,
translate, infer, or rewrite binding declarations.

After editing the user module, inspect normal Lua reload errors with:

```bash
hyprctl configerrors
```

## Open and close the panel

The bar icon opens or closes the panel on that icon's monitor. The desktop
hotkey is Super+Alt+A and must run:

```bash
omarchy-shell shell toggle ollieedgeley.droidpeek
```

so Omarchy picks the focused monitor's copy. Do not use
`omarchy-shell ollieedgeley.droidpeek toggle`; that reaches whichever bar
instance registered the raw IPC target first.

A ready panel focuses the phone preview automatically, including after
reconnection. The preview supports taps, swipes, named Android keys, and
ordinary text. Ctrl, Alt, Meta/Super combinations, key-release ordering, and
clipboard transport are not supported.

## Phone-mode bindings

Phone mode is active only when the panel is open, **Android-mode shortcuts**
is enabled, and the canonical application state is `interactive`. In that
mode, configured chords belong only to Android. An unconfigured desktop chord
is inert rather than falling through to its desktop action. Closing the
panel, disabling Android-mode shortcuts, losing `interactive`, or restarting
the helper resets the submap immediately. Outside phone mode, ordinary
desktop bindings behave normally.

The shipped defaults cover panel close, Home, Recents, Android-local
copy/cut/paste, and supported volume and media keys. Optional app and browser
examples stay commented until you enable them.

| Chord | Description | Target |
| --- | --- | --- |
| Super+Alt+A | Close Android panel | `android.close_panel` |
| Alt+Tab | Recent apps | `android.recent-apps` |
| Super+W | Home | `android.navigate.home` |
| Super+C | Copy | `{ type = "android.keyevent", key = "copy" }` |
| Super+V | Paste | `{ type = "android.keyevent", key = "paste" }` |
| Super+X | Cut | `{ type = "android.keyevent", key = "cut" }` |
| XF86AudioRaiseVolume | Volume up | `{ type = "android.keyevent", key = "volume-up" }` |
| XF86AudioLowerVolume | Volume down | `{ type = "android.keyevent", key = "volume-down" }` |
| XF86AudioMute | Mute | `{ type = "android.keyevent", key = "volume-mute" }` |
| XF86AudioNext | Next track | `{ type = "android.keyevent", key = "media-next" }` |
| Alt+XF86AudioPlay | Next track | `{ type = "android.keyevent", key = "media-next" }` |
| XF86AudioPause | Play/pause | `{ type = "android.keyevent", key = "media-play-pause" }` |
| XF86AudioPlay | Play/pause | `{ type = "android.keyevent", key = "media-play-pause" }` |
| XF86AudioPrev | Previous track | `{ type = "android.keyevent", key = "media-previous" }` |
| Alt+Shift+XF86AudioPlay | Previous track | `{ type = "android.keyevent", key = "media-previous" }` |

The close callback synchronously resets Hyprland before requesting panel
close, so a delayed close acknowledgement cannot strand keyboard ownership.
The Home target leaves the current Android app; it does not claim to
terminate it.

### Add an app binding

```lua
android.bind("SUPER + RETURN", "Termux", {
  type = "android.app.launch",
  package = "com.termux",
})
```

The middle value is the friendly failure label. If the app cannot open, Droid
Peek can show `Couldn't open Termux.` through Omarchy notifications.

With the phone paired, search installed package names:

```bash
adb shell pm list packages | grep -i termux
```

Use the returned text after `package:` in the binding. Android documents this
package-manager query in its [ADB guide](https://developer.android.com/tools/adb).

Supported targets are `android.close_panel`, `android.navigate.home`,
`android.navigate.back`, `android.recent-apps`, a typed `android.app.launch`
object with a validated package name, and typed `android.keyevent` objects.
Arbitrary ADB or shell commands are not accepted.

Each target dispatch sends one base64url-encoded JSON envelope to
`omarchy-shell ollieedgeley.droidpeek phoneTarget`. The envelope has a unique
`requestId`, the direct typed `target`, and a two-second absolute deadline.
QML accepts it only in the interactive state, adds the current helper epoch
and session generation, and sends protocol v11 to Rust. Stale, missing,
invalid, failed, or timed-out attempts are consumed and never run a desktop
fallback.

## scrcpy arguments

Declare optional scrcpy arguments once before the submap and keep
`android.commitConfiguration()` as the final statement:

```lua
android.configure({
  scrcpyArgs = {
    "--keep-active",
    "--turn-screen-off",
    "--stay-awake",
  },
})

android.define_submap("droid-peek", function()
  -- bindings
end)

android.commitConfiguration()
```

Each entry is one argument, not a shell command. The list must be a dense
string list of at most 32 arguments.

Droid Peek reserves device, transport, display, V4L2, window, control,
cleanup, quality, and audio options so the session remains reliable. The API
rejects malformed values and these reserved names:

`--serial`, `--select-usb`, `--select-tcpip`, `--tcpip`, `--video-source`,
`--new-display`, `--display`, `--v4l2-sink`, `--no-video`, `--no-window`,
`--window`, `--control`, `--no-control`, `--no-cleanup`, `--no-power-on`,
`--max-size`, `--video-bit-rate`, `--max-fps`, and any argument whose name
starts with `--audio`.

A valid commit is stored privately and restarts only an active phone session.
When `--turn-screen-off` is configured, it is applied on the first scrcpy
session. Omarchy proves the session with `session-started` plus a valid
preview frame. If no frame arrives within five seconds, the session is
stopped and Preview failed is shown. Removing the option causes one restart
that restores normal scrcpy cleanup behavior. Android lock-screen and
device-policy behavior remain unchanged.

See the template comments before changing `scrcpyArgs`.

## Panel settings

All settings are private global preferences, not per-device profiles. They
survive **Start over**.

| Setting | Default | Behavior |
| --- | --- | --- |
| **Keep phone connected** | Off | Retains an eligible trusted session while the panel is hidden. |
| **Android-mode shortcuts** | On | Activates the configured `droid-peek` submap only while the panel is interactive. |
| **Preview scale** | 100% | Changes the embedded view from 50% through 150% in five-point steps without cropping. |
| **Quality** | High | Selects Low, Medium, or High; changing it restarts only an active mirroring session. |
| **Quick actions** | Back, Home, Recent apps | Assigns any of those three actions independently to each toolbar slot. |

Settings is keyboard navigable. Tab and Shift+Tab move through controls.
Escape first closes an open selector or confirmation, then returns to the
focused phone view.

With **Keep phone connected** off, close also stops the active helper/scrcpy
session. Reopening resolves the phone and starts a new session. With it on,
close may retain an already trusted ready or session-starting connection.
Pairing, disconnected, and failure states are never retained. A connecting
session still releases QML capture until a frame exists.

## Replace the remembered phone

Use **Settings > Start over** to replace the remembered phone. After
confirmation it stops pending and active work, forgets the local service
identity, preserves global preferences, and starts a fresh QR ceremony. It
does not remove the computer from Android's **Paired devices** list; revoke
it on the phone separately if that is required.

## Boundaries

Bindings cannot run arbitrary ADB shell commands. Copy, cut, and paste affect
the focused Android app only; they do not sync the desktop clipboard. There
is no accepted per-device action profile.
