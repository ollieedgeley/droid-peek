# Use and configure Droid Peek

Use this guide for daily controls, bindings, and settings. Canonical chords and
defaults are in the [reference](reference.md).

## Open and close the panel

- Click the Droid Peek bar icon to open the panel on that bar's display.
- Click the icon again to close it.
- While Android mode is active, `Super+Alt+A` also closes it.

A ready panel focuses the preview. Ordinary typing, pointer input, and your
configured Android-mode bindings work there. Unconfigured modifier chords,
key-release tricks, and desktop clipboard synchronization are not forwarded.

## Understand Android mode

Android mode is active only when all three conditions are true:

1. The panel is open.
2. **Android-mode shortcuts** is enabled.
3. The session is interactive.

Then configured chords belong to Android rather than the desktop. An unmapped
desktop chord does nothing; it does not fall through. Close the panel or turn
the setting off to restore normal desktop bindings.

## Edit bindings

Setup creates `~/.config/hypr/droid-peek.lua` once from the shipped example.
Later setup runs preserve that user-owned file. After editing it, check:

```bash
hyprctl configerrors
```

### Optionally add an app launch

Shipped app-launch examples are commented out because their packages may not be
installed. Enable one only after checking its package name:

```lua
android.bind("SUPER + RETURN", "Termux", {
  type = "android.app.launch",
  package = "com.termux",
})
```

The label is used in a normal failure notification such as `Couldn't open
Termux.` Find a package on the paired Android device with:

```bash
adb shell pm list packages | grep -i termux
```

Use the text after `package:`. Allowed targets are `android.close_panel`,
`android.navigate.home`, `android.navigate.back`, `android.recent-apps`, typed
`android.app.launch`, typed `android.component.launch`, and typed
`android.keyevent`. Bindings cannot run arbitrary `adb shell` commands.

### Optionally open an exact component

`android.component.launch` requires both a package and activity:

```lua
android.bind("SUPER + SPACE", "Samsung Finder", {
  type = "android.component.launch",
  package = "com.samsung.android.app.galaxyfinder",
  activity = ".GalaxyFinderActivity",
})
```

The shipped template contains commented `Super+Space` candidates for OnePlus
Global Search, Google App Search, and Samsung Finder. Enable at most one because
they share a chord. They are optional examples, not supported-app guarantees;
package and activity names vary by device and software version.

## Change scrcpy arguments

Set `scrcpyArgs` with `android.configure` before defining the submap, and
always finish with `android.commitConfiguration()`:

```lua
android.configure({
  scrcpyArgs = {
    "--keep-active",
    "--turn-screen-off",
    "--stay-awake",
    "--keyboard=uhid",
  },
})

android.define_submap("droid-peek", function()
  -- bindings
end)

android.commitConfiguration()
```

The shipped configuration includes these arguments by default.
`--keyboard=uhid` presents the desktop keyboard to Android as a physical
keyboard, so compatible devices may hide their on-screen keyboard while you
type. If `--turn-screen-off` produces no frame within five seconds, the session
stops and the panel reports **Preview failed**.

Each item is one argument, with a limit of 32. Reserved serial, V4L2, window,
audio, control, and quality arguments are rejected; see the
[reference](reference.md).

## Change panel settings

Settings are global and survive **Start over**.

| Setting | Default | What it does |
| --- | --- | --- |
| Keep device connected | Off | Retain an established trusted-device session while the panel is hidden |
| Android-mode shortcuts | On | Enable the submap only under the three Android-mode conditions |
| Preview scale | 100% | Scale from 50% to 150% in steps of five without cropping |
| Quality | High | Low, Medium, or High; changing it restarts active mirroring |
| Quick actions | Back, Home, Recents | Choose one action for each toolbar slot |

With **Keep device connected** off, closing stops an active session and then
the helper. With it on, closing may retain an established or starting
trusted-device session. QR or code pairing, idle helpers, and failed connections
are not retained. Reopening reuses a retained session if it remains healthy.

## Pair a new device

Choose **Settings → Start over** and confirm. Droid Peek forgets this computer's
record of the Android device, preserves panel settings, and shows a new QR code.
It does not remove the computer from Android's **Paired devices** list; revoke
that entry on the Android device when needed.
