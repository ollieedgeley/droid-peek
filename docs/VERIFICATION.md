# Verify Droid Peek

Before publishing, the release commit must pass the automated gates below and
the supported real-phone flow must be recorded. Automated tests use fake ADB,
scrcpy, and mDNS boundaries; they do not pair, connect to, or alter a real
phone.

## Automated checks

From the repository root:

```bash
scripts/check.sh
scripts/check-supply-chain.sh
scripts/check-release-version
```

`scripts/check.sh` validates the manifest, exercises the phone-binding
configurator and Lua API, checks cross-language target and protocol
contracts, runs the tested ast-grep ownership rules, lints QML through a
temporary Omarchy import map, runs Qt Quick Tests, and runs Rust format,
Clippy-with-warnings-denied, nextest, and documentation checks. It requires
the Omarchy Qt 6 environment, Lua, `ast-grep`, and `cargo-nextest`.

`scripts/check-supply-chain.sh` requires `cargo-deny` and `cargo-audit`. It
denies known advisories, yanked crates, wildcard dependencies, unapproved
licenses, and unknown registries or Git sources. These network-backed checks
are intentionally separate from the deterministic local gate.

`scripts/check-release-version` rejects an absent, malformed, or mismatched
value among `manifest.json`, `helper/Cargo.toml`, `qml/BuildInfo.qml`, and
`integrations/build-info.lua`.

Run the slower focused coverage gate separately when measuring helper
contracts:

```bash
scripts/check-coverage.sh
```

Coverage requires `cargo-llvm-cov`, `llvm-cov`, `llvm-profdata`, and `jq`. It
enforces measured line-coverage floors for phone-target actions, input
validation, pairing, protocol, persistence, preferences, and runtime deadline
contracts.

## Real-phone evidence

A release that changes pairing, video, input, lifecycle, setup, or cleanup
still requires a manual run on the named physical phone. Do not automate that
run against an unattended device, and do not save complete ADB output. Record
the supported device, Android version, and result for:

1. Fresh plugin install, reviewed source, dry-run setup, confirmed setup, and
   successful first pairing.
2. Re-running setup without duplicate package, helper, V4L2, Lua-module, or
   loader changes.
3. Plugin disabled, enabled, updated, and reopened with its matching helper;
   stale-helper runtime rejection recorded separately.
4. Expected failures for a missing dependency, bad helper checksum, wrong
   helper version, unsupported architecture, and V4L2 collision.
5. Reboot: `/dev/video42` returns with the `Droid Peek` label; the phone
   panel then pairs or reconnects normally. Cleanup configuration removal is
   also proven to remove the empty device after the following reboot.
6. Panel close and helper failure leave no scrcpy or guardian process
   running.
7. Cleanup refuses to remove helper or configuration while Droid Peek is
   active, preserves shared packages, and, once inactive, removes only the
   selected persistence files.

Also verify through visible panel and phone behavior:

- QR pairing, discovered six-digit fallback, cancellation, retry, and secret
  redaction.
- Reconnect, both **Keep phone connected** close paths, and **Start over**.
- Live V4L2 video, rotation and aspect behavior, pointer input, ordinary
  text, and Back, Home, and recent-apps.
- Active default keyboard, media, and volume bindings.
- Phone-submap entry and reset, mandatory reset-before-close, direct target
  dispatch without desktop fallback, Android-mode disable, and ordinary
  unmodified typing while phone mode is active.
- Dependency, authorization, network, and recovery states without exposing an
  endpoint, code, secret, or complete subprocess output.

An Android emulator is useful for ready-surface geometry, video, input, and
session lifecycle. It is not evidence for QR, mDNS, vendor, or real-Wi-Fi
acceptance; those checks require a physical Android 16 phone. Do not describe
emulator QR pairing as a supported workflow.

Any temporary optional-app acceptance test is local evidence only. It must
restore the original user configuration and never become a shipped default.
