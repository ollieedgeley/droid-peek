# Fix Droid Peek problems

Read the setup or panel message first. Droid Peek stops instead of guessing.
Use the [installation guide](how-to-install-update-remove.md) for the complete
setup and cleanup contracts.

## Setup stopped

From the plugin checkout, print the plan without changing the host:

```bash
scripts/setup-droid-peek --dry-run
```

Common hard stops are:

- The plugin is enabled. Disable it before setup.
- The architecture, running kernel, headers, or a required package does not
  match setup's checks.
- The matching helper asset or `SHA256SUMS` is unavailable, malformed, or does
  not match the helper version. A tracked version does not prove a GitHub
  release asset has been published.
- `/dev/video42` has the wrong label or users, or another loopback exists. Do
  not invent a second Droid Peek camera.
- Omarchy's existing `avahi-daemon.service` is not active. Setup does not enable
  it.

For an intentionally supplied local helper, verify the directory contains the
exact versioned helper and one-entry `SHA256SUMS`, then run:

```bash
DROID_PEEK_HELPER_ASSET_DIR=/path/to/assets \
  scripts/setup-droid-peek --yes
```

`--yes` is required for a non-interactive real run. It skips confirmation, not
preflight, checksum, version, or final verification.

## The icon or helper is unavailable

Confirm the checkout is at
`~/.config/omarchy/plugins/ollieedgeley.droidpeek/`, the helper is executable at
`~/.local/bin/droid-peek-helper`, and setup finished. Then enable the plugin:

```bash
omarchy plugin enable ollieedgeley.droidpeek
```

Updated QML with an old helper fails the version handshake. Disable the plugin,
run setup for the matching version, and enable it again.

## Pairing or reconnecting fails

Keep the computer and Android device on the same local network. Leave
**Wireless debugging** open, unlock the device, and accept its prompt.

Pair-by-code still uses Avahi. Droid Peek has no typed IP-and-port fallback. If
the device is offline, restore Wi-Fi and Wireless debugging, then choose
**Reconnect**. To pair another device or reset pairing, choose **Settings →
Start over**.

USB is useful only for reviewing Android's debugging authorization. Droid Peek
does not change USB state. Unplug, leave Wireless debugging enabled, and choose
**Reconnect**. **Start over** does not remove the computer from Android's
**Paired devices** list.

## The preview is empty

```bash
cat /sys/class/video4linux/video42/name
```

The output must be `Droid Peek`. Close and reopen the panel. Do not unload
`v4l2loopback` when another process uses it.

If `--turn-screen-off` produces no frame within five seconds, the panel reports
**Preview failed**. Review [scrcpy arguments](how-to-use-and-configure.md#change-scrcpy-arguments).

## A shortcut does nothing

```bash
hyprctl configerrors
```

Confirm the managed loader and `~/.config/hypr/droid-peek.lua` exist. Android
mode requires all three conditions: the panel is open, **Android-mode
shortcuts** is enabled, and the session is interactive. `Super+Alt+A` closes
the panel only under those conditions.

## Cleanup refuses

Disable the plugin and close the panel, then run:

```bash
scripts/cleanup-droid-peek --dry-run
```

Cleanup refuses while a Droid Peek helper or scrcpy process is active or
`/dev/video42` has users. It never removes shared packages, Avahi, or unrelated
V4L2 configuration.

## Keep secrets out of reports

Do not publish pairing codes, QR payloads, device endpoints, or full ADB and
scrcpy dumps.
