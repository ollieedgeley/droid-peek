# Install and maintain Droid Peek

This is the authoritative install, upgrade, and cleanup reference. The
[README](../README.md) is only the happy path.

## Prerequisites

The first release supports an x86_64 Arch Linux installation running Omarchy 4
and its Quickshell bar-plugin runtime, plus one Android 16 phone on the same
trusted local network. No ARM, generic Linux, earlier Omarchy, or Android 14/15
support is claimed.

The running kernel must come from Arch's `linux` package. A non-stock kernel
is unsupported: setup fails before changing the host and tells you to install
matching headers yourself.

Install these packages first with `omarchy pkg add`. Setup never installs
packages, never invokes `pacman`, and never enables a system service.

- `android-tools`, providing `adb`
- `avahi`, providing `avahi-browse` and the Avahi daemon
- `scrcpy`
- `qt6-multimedia`
- `v4l2loopback-dkms`
- `linux-headers` matching the running stock kernel

Plugin QML runs unsandboxed inside the long-running `omarchy-shell` process.
Review the checkout and its updates before enabling the plugin. The helper is a
child process with access to ADB, Avahi, scrcpy, the private V4L2 device, and
the plugin's private state directory.

## Prepare the phone

1. Enable Developer options. The Android settings path varies by manufacturer.
2. Open **Developer options** and enable **Wireless debugging**.
3. Allow wireless debugging on the trusted network you share with the desktop.

Follow Android's official
[Wireless debugging guide](https://developer.android.com/studio/run/device.html).

Keep Wireless debugging open while pairing or reconnecting. Treat it as
trusted-network access, and disable it on Android when it is not needed.

## Install

Installation is two explicit stages. Omarchy does not run plugin code, install
hooks, or escalate privilege during `plugin add`.

### Stage one: install reviewed plugin source

```bash
omarchy plugin add https://github.com/ollieedgeley/droid-peek.git
```

Omarchy clones the source to
`~/.config/omarchy/plugins/ollieedgeley.droidpeek/` and, in an interactive
terminal, asks whether to enable it. Decline. Setup begins by confirming that
`ollieedgeley.droidpeek` is still disabled and refuses to alter the host if the
plugin is already enabled.

Review the checkout before continuing.

### Stage two: explicit Droid Peek setup

From the reviewed checkout:

```bash
cd ~/.config/omarchy/plugins/ollieedgeley.droidpeek
scripts/setup-droid-peek --dry-run
scripts/setup-droid-peek
```

`--dry-run` and a normal run both print the complete planned operation before
any host mutation: helper asset, version, and install path, persistent V4L2
files, Avahi prerequisite status, and user Lua configuration action. A normal
interactive run asks once with `gum` before the first host mutation. Pass
`--yes` for non-interactive use. `--dry-run` and `--yes` never call `gum`.

Setup then:

1. Validates the release identity and version, then confirms the supported
   x86_64 platform, stock `linux` kernel, matching
   `/usr/lib/modules/$(uname -r)/build` headers, and a ready `v4l2loopback`
   DKMS build for that kernel.
2. Confirms `avahi-daemon.service` is already active. Setup does not enable
   Avahi.
3. Downloads the version-matched helper from
   `https://github.com/ollieedgeley/droid-peek/releases/download/v<version>/`,
   verifies the strict `SHA256SUMS` entry and `droid-peek-helper --version`,
   and installs the binary mode `0755` at `~/.local/bin/droid-peek-helper`.
4. Provisions the dedicated V4L2 device described below.
5. Copies `integrations/droid-peek.lua.example` to
   `~/.config/hypr/droid-peek.lua` only when that file is absent, and appends
   the managed `require("hypr.droid-peek")` loader block to
   `~/.config/hypr/bindings.lua` only when that block is absent.
6. Verifies helper version, V4L2 path and label, Avahi availability, plugin
   discovery, and the user-module and loader result.

Setup fails closed when the checked-out versions disagree, the matching
release or asset is unavailable, or the checksum, architecture, headers, DKMS
build, or helper version is invalid. It never substitutes an arbitrary
executable from `PATH`.

If a later stage fails after the helper, V4L2 files, or loader are installed,
setup reports that partial state and the matching
`scripts/cleanup-droid-peek --yes` recovery command. It never silently
rewrites the user module or bindings file.

Setup never enables the plugin. After verification succeeds it prints:

```bash
omarchy plugin enable ollieedgeley.droidpeek
```

Run that command yourself. Setup must not enable a half-configured plugin.

## Persistent V4L2 device

Setup owns exactly these persistent configuration files:

```text
/etc/modules-load.d/droid-peek.conf
/etc/modprobe.d/droid-peek.conf
```

The modules-load file contains only `v4l2loopback`. The modprobe file
configures exactly one device with `video_nr=42`, `card_label="Droid Peek"`,
and `exclusive_caps=0`.

`exclusive_caps=0` is required for the long-running Quickshell process. The
shell can initialize Qt Multimedia before scrcpy starts; output-only
advertisement hides the loopback from that process for the rest of its
lifetime.

When `v4l2loopback` is not loaded, setup writes the two files, loads the
module once, and verifies the exact device and label. When the module is
already loaded, setup never unloads or reloads that shared module. It may
write the persistent files only when `/dev/video42` is already the exact
inactive `Droid Peek` device and no other loopback device exists; otherwise it
fails with a reboot or manual-recovery instruction. Any path, label,
active-user, or additional-loopback-device collision is a hard failure with no
overwrite.

The empty device remains after panel close and across reboot. It does not run
scrcpy or process phone frames while no writer or reader is attached. Opening
the interactive panel starts scrcpy and the QML capture path; closing them
releases the device while retaining the dedicated endpoint.

If `v4l2-ctl` is available, inspect the approved device with:

```bash
v4l2-ctl --list-devices
```

The output must associate `Droid Peek` with `/dev/video42`. That fixed
path-and-label pair is the capture endpoint contract. Alternate sink path
environment overrides are not supported.

## Helper install path

Panel and the Hyprland Lua integration resolve only
`~/.local/bin/droid-peek-helper`. Neither launches a bare helper name from
`PATH`. Before Panel starts a session or Lua stores scrcpy arguments, each
invokes that absolute path with `--version` and compares the output to its
generated BuildInfo value. A missing, nonzero, malformed, or mismatched
result prevents the operation and reports local recovery.

## Update

Updates preserve user-owned Lua configuration, trusted-device state, and
preferences by default.

1. Close the Droid Peek panel.
2. Disable the plugin:

   ```bash
   omarchy plugin disable ollieedgeley.droidpeek
   ```

3. Run Omarchy's diff-reviewed fast-forward update.
4. From the plugin checkout, run `scripts/setup-droid-peek` so it can verify
   or replace the matching helper.
5. Enable the plugin:

   ```bash
   omarchy plugin enable ollieedgeley.droidpeek
   ```

Re-running setup on an already configured host must not duplicate helper,
V4L2, Lua-module, or loader changes. Opening newly updated QML against
a stale helper outside this flow fails closed at the runtime version handshake.

## Cleanup and uninstall

Disable Droid Peek, close its panel, and run cleanup before removing the Git
checkout:

```bash
omarchy plugin disable ollieedgeley.droidpeek
scripts/cleanup-droid-peek
omarchy plugin remove ollieedgeley.droidpeek
```

Cleanup presents separate, unchecked-by-default choices to remove:

1. `~/.local/bin/droid-peek-helper`
2. The two Droid Peek V4L2 configuration files
3. User-owned Lua configuration
4. Droid Peek trusted-device state and preferences

Before any cleanup mutation, the script verifies that Droid Peek is disabled,
its panel is closed, no Droid Peek helper process is running, no scrcpy
descendant of that helper is running, and `/dev/video42` has no users. If any
check fails, cleanup makes no change. An unrelated scrcpy process is not a
Droid Peek process.

Cleanup always removes only its exact managed loader block whether or not the
user retains `~/.config/hypr/droid-peek.lua`. Bare
`scripts/cleanup-droid-peek --yes` is non-interactive loader-only cleanup; it
does not select optional removals. Add `--remove-helper`, `--remove-v4l2`,
`--remove-user-config`, and `--remove-state` explicitly when those files
should go too.

Cleanup never removes shared packages, the Avahi package or service, or
unrelated V4L2 configuration. It does not unload the shared V4L2 module or
remove the live device. When the V4L2 configuration files are selected for
removal, the idle device disappears only after reboot.

Private device identity and preferences live under
`${XDG_STATE_HOME:-$HOME/.local/state}/droid-peek`. Remove that directory
only when intentionally forgetting the phone and every setting.

Loader addition and removal are idempotent. Removal deletes only the exact
managed block and preserves all other Hyprland configuration bytes.
