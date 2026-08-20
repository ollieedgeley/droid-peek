# How Droid Peek works

This explanation describes why Droid Peek has separate QML, Rust, Lua, scrcpy,
and V4L2 pieces.

## The data path

1. Wireless debugging pairs one Android device with ADB.
2. `droid-peek-helper` discovers and owns that remembered device session.
3. Unmodified scrcpy writes video frames to `/dev/video42`, labelled
   **Droid Peek**.
4. Qt Multimedia shows that named camera in the Omarchy panel.
5. Only validated pointer, keyboard, quick-action, and Lua-binding inputs return
   to the Android device.

QML owns the panel and presentation state. Rust owns pairing, persistence, ADB,
Avahi discovery, scrcpy, and process lifecycle. Lua defines the Android-mode
submap. Droid Peek does not fork or patch scrcpy.

## Pair once and rediscover by name

QR pairing is the normal path. Six-digit pair-by-code is a fallback that still
uses Avahi. There is no typed IP-and-port mode.

After pairing, the helper stores one mDNS service name rather than a network
address. Every reconnect resolves that name again, so it does not reuse a stale
host and port.

## Use a dedicated virtual camera

The Omarchy shell is long-lived, and Qt Multimedia may enumerate cameras before
scrcpy starts. `exclusive_caps=0` keeps `/dev/video42` visible to that process.
A fixed label and device number keep the panel from selecting a webcam.

The empty V4L2 node remains when the panel closes and after reboot. It carries
no frames until a Droid Peek session starts scrcpy.

## Retain only an eligible session

With **Keep device connected** off, closing the panel asks the helper to stop
the session and then stops the helper. With it on, closing may retain an
established or starting trusted-device session. QR or code pairing, idle
helpers, and failed connections are cancelled or stopped rather than retained.
This is retain-on-hide, not a permanent network connection.

scrcpy runs behind a guardian process whose parent-death signal ties it to the
helper. An abrupt helper exit therefore makes the guardian stop scrcpy instead
of leaving video production orphaned.

## Keep the input boundary narrow

Bindings cannot become arbitrary `adb shell` commands. Lua accepts only the
listed navigation, application, component, and key-event targets, validates
them, and sends the typed action through the helper protocol. Copy, cut, and
paste remain inside Android; there is no desktop clipboard bridge, cloud
service, or app inventory.

Pairing codes, QR material, and device endpoints are redacted from normal
status and error output. Wireless debugging is still trusted-local-network ADB;
disable it on the Android device when it is not wanted.

## Repository responsibilities

| Area | Responsibility |
| --- | --- |
| `BarWidget.qml`, `Panel.qml`, `qml/` | Bar item, panel, preview, settings, and presentation state |
| `helper/` | Protocol, state, ADB, Avahi, scrcpy, and process lifecycle |
| `integrations/phone-bindings.lua` | Stable internal Lua submap API |
| `integrations/droid-peek.lua.example` | First-run user configuration template |
| `scripts/setup-droid-peek` | User-facing host setup and verification |
| `scripts/cleanup-droid-peek` | User-facing managed cleanup |
| `scripts/dev/check.sh` and other `scripts/dev/*` checks | Read-only maintainer gates |

The internal `phone-bindings.lua` filename is preserved for compatibility; it
is not user-visible device terminology.
