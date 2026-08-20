#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"
qt6_bin="${QT6_BIN:-/usr/lib/qt6/bin}"
apply_fix=0

if [[ "${1:-}" == "--fix" ]]; then
  apply_fix=1
  shift
fi

qml_files=(
  BarWidget.qml
  Panel.qml
  qml/BuildInfo.qml
  qml/components/NestedEscapeScope.qml
  qml/components/PhonePreview.qml
  qml/components/PhoneToolbar.qml
  qml/components/Settings.qml
  qml/state/ApplicationState.qml
  qml/state/PairingState.qml
  qml/state/PhoneTargetRouter.qml
  qml/state/SubmapController.qml
)

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

if [[ "$apply_fix" -eq 1 ]]; then
  "$qt6_bin/qmllint" -I "$lint_root" -f -- "${qml_files[@]}"
fi

"$qt6_bin/qmllint" -I "$lint_root" -- "${qml_files[@]}"
