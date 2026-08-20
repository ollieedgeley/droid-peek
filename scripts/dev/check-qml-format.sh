#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
qt6_bin="${QT6_BIN:-/usr/lib/qt6/bin}"
settings="$root_dir/.qmlformat.ini"

cd "$root_dir"
shopt -s globstar nullglob
qml_files=(./*.qml qml/**/*.qml)

if [[ ! -f "$settings" ]]; then
  printf 'missing committed qmlformat settings: %s\n' "$settings" >&2
  exit 1
fi
if [[ ! -x "$qt6_bin/qmlformat" ]]; then
  printf 'qmlformat not found at %s/qmlformat\n' "$qt6_bin" >&2
  exit 1
fi

format_root="$(mktemp -d "${TMPDIR:-/tmp}/droid-peek-qmlformat.XXXXXX")"
cleanup_format_root() {
  rm -rf "$format_root"
}
trap cleanup_format_root EXIT


status=0
for file in "${qml_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    printf 'missing QML file: %s\n' "$file" >&2
    status=1
    continue
  fi

  formatted="$format_root/${file//\//_}"
  if ! "$qt6_bin/qmlformat" -- "$file" >"$formatted"; then
    printf 'qmlformat failed for %s\n' "$file" >&2
    status=1
    continue
  fi
  if ! diff -u --label "$file" --label "$file (qmlformat)" \
    "$file" "$formatted"; then
    status=1
  fi
done

if [[ "$status" -ne 0 ]]; then
  printf 'QML format-parity failed. The gate never runs qmlformat --inplace.\n' >&2
fi
exit "$status"
