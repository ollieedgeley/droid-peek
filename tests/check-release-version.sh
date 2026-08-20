#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$root_dir/scripts/dev/check-release-version"
generator="$root_dir/scripts/dev/generate-build-info"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droid-peek-release-version.XXXXXX")"

cleanup_test() {
  rm -rf "$test_root"
}
trap cleanup_test EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ -x "$checker" ]] || fail "missing release check: $checker"
[[ -x "$generator" ]] || fail "missing build-info generator: $generator"

write_tree() {
  local dest="$1"
  mkdir -p "$dest/scripts/dev" "$dest/qml" "$dest/integrations" "$dest/helper"
  cat >"$dest/manifest.json" <<'EOF'
{
  "id": "ollieedgeley.droidpeek",
  "version": "1.0.0"
}
EOF
  cat >"$dest/helper/Cargo.toml" <<'EOF'
[package]
name = "droid-peek-helper"
version = "1.0.0"
EOF
  cp "$generator" "$dest/scripts/dev/generate-build-info"
  cp "$checker" "$dest/scripts/dev/check-release-version"
  chmod +x "$dest/scripts/dev/generate-build-info" "$dest/scripts/dev/check-release-version"
  (cd "$dest" && scripts/dev/generate-build-info)
}

synced="$test_root/synced"
write_tree "$synced"
if ! "$synced/scripts/dev/check-release-version" >/dev/null; then
  fail "synced generated BuildInfo must pass check-release-version"
fi

drift="$test_root/drift"
write_tree "$drift"
cat >"$drift/qml/BuildInfo.qml" <<'EOF'
import QtQuick

QtObject {
    readonly property string releaseVersion: "1.0.0"
    readonly property string note: "hand-edited"
}
EOF
if drift_output="$("$drift/scripts/dev/check-release-version" 2>&1)"; then
  fail "hand-edited BuildInfo must fail check-release-version"
fi
[[ "$drift_output" == *'generate-build-info'* || "$drift_output" == *'BuildInfo'* ]] ||
  fail "drift failure must mention generate-build-info or BuildInfo"
