# Troubleshooting Droid Peek

Read the setup or panel message before retrying. Droid Peek stops rather than
guessing when a dependency, helper checksum, V4L2 device, or existing
configuration is unsafe.

## Setup stops

Run `scripts/setup-droid-peek --dry-run` from
`~/.config/omarchy/plugins/ollieedgeley.droidpeek` to review the next attempt.

Typical hard failures:

- The plugin is already enabled. Disable it, then rerun setup.
- The host is not x86_64, or the kernel is not Arch's stock `linux` package.
- A required package is missing and `omarchy pkg add` cannot install it.
- The matching GitHub Release asset is unavailable, its `SHA256SUMS` entry is
  absent or malformed, or the helper checksum or `--version` does not match
  the checked-out manifest.
- `/dev/video42` already exists with the wrong label, is in use, or another
  loopback device is present. Do not create another virtual camera. Reboot or
  recover the dedicated `Droid Peek` device manually, then rerun setup.

Setup never substitutes an arbitrary helper from `PATH` and never overwrites
a colliding V4L2 configuration.

## Widget or helper unavailable

Confirm the plugin checkout is at
`~/.config/omarchy/plugins/ollieedgeley.droidpeek`, the helper is installed at
`~/.local/bin/droid-peek-helper`, and setup finished successfully. Then enable
the plugin:

```bash
omarchy plugin enable ollieedgeley.droidpeek
```

If you just updated QML without rerunning setup, a stale helper is rejected
at the runtime version handshake. Disable the plugin, run
`scripts/setup-droid-peek`, then enable it again.

## Local dependency unavailable

Confirm `adb`, `avahi-browse`, and `scrcpy` are installed and available to
`omarchy-shell`, and that Avahi is running. Recheck the separately approved
V4L2 device and Qt Multimedia package.

## Phone will not pair or reconnect

Keep Wireless debugging open, keep both devices on the same trusted Wi-Fi,
and allow mDNS traffic. Unlock the phone, approve its Wireless debugging
prompt, and retry.

The six-digit path still depends on Avahi discovery for the temporary
endpoint. It cannot bypass unavailable mDNS with a manual address and port.

If the session ends or the phone is offline, restore the same trusted Wi-Fi
and Wireless debugging, then select **Reconnect**. If the phone was replaced
or its pairing was reset, use **Settings > Start over** rather than editing
the private state file.

Authorization recovery may require connecting the unlocked phone over USB
only long enough to review or restore debugging authorization through normal
Android and ADB tooling. The plugin will not automate or change USB
configuration. Disconnect USB, leave Wireless debugging enabled, and select
**Reconnect**.

Start over does not remove the computer from Android's **Paired devices**
list. Revoke it on the phone separately if that is required.

## No phone preview

Do not create another virtual camera. Confirm that `/dev/video42` is labelled
`Droid Peek`, is writable by the user, and is not held by a stale producer:

```bash
v4l2-ctl --list-devices
```

Close and reopen the panel to start fresh QML and scrcpy consumers. Do not
unload `v4l2loopback` while another loopback user needs it.

If `--turn-screen-off` is configured and no frame arrives within five
seconds, the session is stopped and Preview failed is shown. Remove or keep
that option only after reading [CONFIGURATION.md](CONFIGURATION.md).

## Phone shortcut does nothing

Check `hyprctl configerrors`. Confirm the managed loader block and
`~/.config/hypr/droid-peek.lua` are present, enable **Android-mode
shortcuts**, close Settings, and wait for the phone state to become
interactive. Target failures are consumed and never invoke a desktop action.

The bar icon opens or closes the panel. Super+Alt+A closes it only while
phone mode is active. Do not use
`omarchy-shell ollieedgeley.droidpeek toggle`; that can reach the wrong bar
instance. Use `omarchy-shell shell toggle ollieedgeley.droidpeek` so Omarchy
picks the focused monitor's copy.

## Cleanup refuses to run

Cleanup makes no change while Droid Peek is enabled, its panel is open, a
helper, scrcpy, or guardian process is running, or `/dev/video42` has users.
Disable the plugin, close the panel, then rerun `scripts/cleanup-droid-peek`.

Cleanup never removes shared packages, Avahi, or unrelated V4L2
configuration. Selecting the Droid Peek V4L2 files removes only those
persistent files; the idle device disappears after the following reboot.

## Keep secrets out of reports

Never share pairing codes, QR payloads, discovered endpoints, private device
identifiers, or complete ADB or scrcpy output. The helper acceptance log
contains only fixed, redacted protocol events. If a preview problem persists,
collect only the safe diagnostic information requested in a bug report.
