# Install, update, or remove Droid Peek

Use these recipes from an Omarchy machine. The [README](../README.md) is the
short happy path; canonical names and paths are in the [reference](reference.md).

## Install

Keep Droid Peek disabled until setup finishes all verification.

### 1. Install the host dependencies

```bash
omarchy pkg add scrcpy qt6-multimedia v4l2loopback-dkms linux-headers
```

Omarchy adds only packages that are missing and owns their normal updates.
Avahi is already provided by Omarchy; `scrcpy` pulls in `android-tools`, and
`v4l2loopback-dkms` pulls in `dkms`. Droid Peek setup does not install or remove
packages.

### 2. Add the source

```bash
omarchy plugin add https://github.com/ollieedgeley/droid-peek.git
```

Decline the enable prompt, then review the checkout at
`~/.config/omarchy/plugins/ollieedgeley.droidpeek/`. Setup refuses to change
the host while the plugin is enabled.

### 3. Run setup

```bash
cd ~/.config/omarchy/plugins/ollieedgeley.droidpeek
scripts/setup-droid-peek --dry-run
scripts/setup-droid-peek
```

Both invocations print the complete plan. `--dry-run` makes no changes. A
normal interactive run asks once with `gum` before its first host change. For
intentional automation, use:

```bash
scripts/setup-droid-peek --yes
```

`--yes` skips that prompt. A non-interactive real run without `--yes` refuses
to proceed instead of waiting for input.

Setup performs these steps:

1. Checks the repository release version, x86_64 architecture, the stock Arch
   `linux` kernel and matching headers, DKMS v4l2loopback, and disabled plugin.
2. Obtains the helper selected by `manifest.json`, verifies its single-entry
   `SHA256SUMS` and `--version`, then installs it at
   `~/.local/bin/droid-peek-helper`.
3. Checks that Omarchy's existing `avahi-daemon.service` is active. Setup never
   enables or owns that service.
4. Prepares the dedicated `/dev/video42` device labelled **Droid Peek**.
5. Copies `integrations/droid-peek.lua.example` to
   `~/.config/hypr/droid-peek.lua` only when the user file is absent, and adds
   the managed `require("hypr.droid-peek")` loader only when it is absent.
6. Verifies the helper, V4L2 device, local discovery, plugin discovery, user
   configuration, and managed loader.

By default, setup requests the versioned helper and `SHA256SUMS` from the
matching GitHub release URL. The repository and setup script do not prove that
those files have been published, so confirm the matching release files are
available before relying on that route.

For tests or offline verification, point setup at a local asset directory:

```bash
DROID_PEEK_HELPER_ASSET_DIR=/path/to/assets \
  scripts/setup-droid-peek --yes
```

That directory must contain `droid-peek-helper-<version>-x86_64-unknown-linux-gnu`
and `SHA256SUMS`; the checksum file must contain exactly one entry naming that
helper. This override replaces downloading. It does not skip checksum or
version verification, and the helper is never selected from `PATH`.

If setup fails after making a host change, read its printed recovery command.
It reports the partial state instead of silently rewriting user Lua.

### 4. Enable the plugin

Only after setup reports successful verification:

```bash
omarchy plugin enable ollieedgeley.droidpeek
```

## Optionally verify future release provenance

A release asset and GitHub provenance attestation are not established by the
tracked repository alone. If a published release later supplies an attestation,
download its versioned helper asset and verify that exact file independently:

```bash
gh attestation verify /path/to/droid-peek-helper-<version>-x86_64-unknown-linux-gnu \
  --repo ollieedgeley/droid-peek
```

Do not treat this command as evidence that an attestation currently exists.
Normal setup verifies the helper checksum and version; provenance verification
is an optional additional check.

## Understand the camera configuration

Setup owns only these system files:

```text
/etc/modules-load.d/droid-peek.conf
/etc/modprobe.d/droid-peek.conf
```

They describe one loopback device: `video_nr=42`, label `Droid Peek`, and
`exclusive_caps=0`. The last setting keeps the device visible to the
long-running Omarchy shell before scrcpy starts producing frames.

If `v4l2loopback` is already loaded, setup never unloads it. It writes the
files only when `/dev/video42` is already the idle **Droid Peek** device and no
other loopback exists; a collision is a hard stop. The empty device remains
after the panel closes and after reboot.

Check its label with:

```bash
cat /sys/class/video4linux/video42/name
```

The output must be `Droid Peek`.

## Update

The user Lua file, remembered Android device, and preferences are preserved.
From the checkout:

```bash
omarchy plugin disable ollieedgeley.droidpeek
omarchy plugin update ollieedgeley.droidpeek
scripts/setup-droid-peek
omarchy plugin enable ollieedgeley.droidpeek
```

Use `DROID_PEEK_HELPER_ASSET_DIR` on the setup command if the matching helper
is supplied locally. Re-running setup preserves existing user Lua, avoids
duplicating the managed loader or V4L2 configuration, and installs one
version-verified helper at the canonical path. New QML rejects a stale helper
during its version handshake.

## Remove

First inspect the cleanup plan:

```bash
omarchy plugin disable ollieedgeley.droidpeek
scripts/cleanup-droid-peek --dry-run
scripts/cleanup-droid-peek
omarchy plugin remove ollieedgeley.droidpeek
```

Interactive cleanup always removes the managed loader and asks separately,
unchecked by default, whether to remove:

1. `~/.local/bin/droid-peek-helper`
2. The two Droid Peek V4L2 configuration files
3. `~/.config/hypr/droid-peek.lua`
4. Trusted-device state and preferences

For deliberate non-interactive cleanup, name every optional removal you want:

```bash
scripts/cleanup-droid-peek --yes \
  --remove-helper --remove-v4l2 --remove-user-config --remove-state
```

With `--yes` and no `--remove-*` flags, cleanup removes only the managed loader.
Cleanup refuses to run while the plugin or Droid Peek processes are active or
`/dev/video42` has users. It never removes packages, Avahi, unrelated V4L2
configuration, or the loaded module. If the V4L2 files are removed, the idle
device disappears after the next reboot.

Trusted-device state and preferences live in
`${XDG_STATE_HOME:-$HOME/.local/state}/droid-peek`. Remove that directory only
when you intend to forget the Android device and reset every setting.
