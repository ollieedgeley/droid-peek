#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"
qt6_bin="${QT6_BIN:-/usr/lib/qt6/bin}"
lint_root="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-android-qml.XXXXXX")"

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
run_check "test semantic action dispatcher" tests/semantic-action-dispatcher.sh
run_check "test Hyprland integration" lua tests/hyprland-integration.lua integrations/hyprland.lua
run_check "test Hyprland routing configuration" lua tests/hyprland-routing-config.lua integrations/hyprland.lua
run_check "check architecture contracts" scripts/check-architecture.sh
run_check "lint QML" "$qt6_bin/qmllint" -I "$lint_root" BarWidget.qml Panel.qml qml/components/NestedEscapeScope.qml qml/components/PhonePreview.qml qml/components/PhoneToolbar.qml qml/components/Settings.qml qml/state/PairingState.qml qml/state/SemanticActionRouter.qml
run_check "run QML tests" "$qt6_bin/qmltestrunner" -input tests/qml
run_check "check Rust formatting" cargo fmt --manifest-path helper/Cargo.toml -- --check
run_check "lint Rust" cargo clippy --manifest-path helper/Cargo.toml --all-targets --all-features --locked -- -D warnings
run_check "test Rust helper" cargo nextest run --manifest-path helper/Cargo.toml --locked
run_check "build Rust documentation" env RUSTDOCFLAGS="-D warnings" cargo doc --manifest-path helper/Cargo.toml --no-deps --locked
