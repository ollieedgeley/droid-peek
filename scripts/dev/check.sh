#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"
qt6_bin="${QT6_BIN:-/usr/lib/qt6/bin}"
lint_root="$(mktemp -d "${TMPDIR:-/tmp}/droid-peek-qml.XXXXXX")"

cleanup_lint_root() {
  unlink "$lint_root/qs/Ui" 2>/dev/null || true
  unlink "$lint_root/qs/Commons" 2>/dev/null || true
  rmdir "$lint_root/qs" 2>/dev/null || true
  rmdir "$lint_root" 2>/dev/null || true
}

trap cleanup_lint_root EXIT

cd "$root_dir"
mkdir -p "$lint_root/qs"
ln -s "$omarchy_path/shell/Ui" "$lint_root/qs/Ui"
ln -s "$omarchy_path/shell/Commons" "$lint_root/qs/Commons"

run_check() {
  printf '==> %s\n' "$1"
  shift
  "$@"
}

run_check "validate plugin manifest" omarchy plugin validate .
run_check "check release version" scripts/dev/check-release-version
run_check "test release version lock" tests/check-release-version.sh
run_check "test release workflow ShellCheck" tests/release-workflow-shellcheck.sh
run_check "test panel-open docs" tests/docs-panel-open.sh
run_check "test installed theme alignment" tests/theme-alignment.sh
run_check "test phone-binding configurator" tests/semantic-action-dispatcher.sh
run_check "test setup and cleanup" tests/setup-droid-peek.sh
run_check "test phone-binding API" lua tests/hyprland-integration.lua integrations/phone-bindings.lua
run_check "test phone-binding template" lua tests/hyprland-routing-config.lua integrations/phone-bindings.lua
run_check "check architecture contracts" scripts/dev/check-architecture.sh
run_check "lint QML" scripts/dev/lint-qml.sh
run_check "check QML format" scripts/dev/check-qml-format.sh
run_check "run QML tests" "$qt6_bin/qmltestrunner" -import "$lint_root" -import "$root_dir/tests/qml/imports" -input tests/qml
run_check "lint Rust" scripts/dev/lint-rust.sh
run_check "check unused Rust dependencies" cargo machete --with-metadata --skip-target-dir helper
run_check "test Rust helper" cargo nextest run --manifest-path helper/Cargo.toml --locked
run_check "build Rust documentation" env RUSTDOCFLAGS="-D warnings" cargo doc --manifest-path helper/Cargo.toml --no-deps --locked
