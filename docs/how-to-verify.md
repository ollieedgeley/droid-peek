# Verify Droid Peek

This guide is for maintainers preparing project and release evidence. Automated
checks use fakes and do not touch a real Android device.

## Run the read-only maintainer checks

From the repository root:

```bash
scripts/dev/check.sh
scripts/dev/check-architecture.sh
scripts/dev/check-supply-chain.sh
scripts/dev/check-release-version
scripts/dev/check-coverage.sh
```

`check.sh` needs the Omarchy Qt 6 environment, Lua, `ast-grep`, and
`cargo-nextest`. Supply-chain checks need `cargo-deny` and `cargo-audit`.
`check-release-version` requires `manifest.json`, `helper/Cargo.toml`,
`qml/BuildInfo.qml`, and `integrations/build-info.lua` to agree. Coverage is the
slower focused gate.

These commands verify tracked project state. They do not prove that a matching
GitHub helper asset, `SHA256SUMS`, or provenance attestation has been published;
confirm release-page evidence independently. Do not use mutating formatter or
fix commands as verification.

## Exercise a physical Android device

Changes to pairing, video, input, lifecycle, setup, or cleanup need a named
physical Android device. Do not save complete ADB output. Record the device,
Android software version, and result for:

1. Fresh dependency install, plugin add, setup dry-run, setup, and first pair.
2. Repeated setup: existing user Lua is unchanged, the loader and V4L2
   configuration are not duplicated, and one matching helper remains.
3. Disable, update, setup, and enable; also confirm stale-helper rejection.
4. Expected failures: missing dependency, unavailable or bad helper/checksum,
   wrong helper version, inactive Avahi, and V4L2 collision.
5. Reboot: `/dev/video42` is still labelled **Droid Peek** and the panel
   reconnects. Removing the V4L2 files makes the idle node disappear only after
   the next reboot.
6. With **Keep device connected** off, closing the panel stops the active
   session and helper; no scrcpy or guardian remains. With it on, closing
   retains an established trusted-device session and reopening reuses it.
   Closing during pairing, idle, or failure does not retain the helper. In both
   settings, forced helper death must make the guardian stop scrcpy.
7. Cleanup refuses while active. Once idle, it removes the loader and only the
   optional files selected, while preserving packages, Avahi, and unrelated
   V4L2 configuration.

Also exercise QR and pair-by-code, reconnect, **Start over**, preview and input,
default chords, the three Android-mode conditions, submap reset, and redacted
errors.

An emulator can support preview-geometry and input checks. It is not evidence
for QR pairing, mDNS discovery, or real Wi-Fi behavior.
