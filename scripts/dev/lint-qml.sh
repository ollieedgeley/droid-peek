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

cd "$root_dir"
shopt -s globstar nullglob
qml_files=(./*.qml qml/**/*.qml)

lint_root="$(mktemp -d "${TMPDIR:-/tmp}/droid-peek-qml.XXXXXX")"
compiler_root="$lint_root/compiler"

cleanup_lint_root() {
  rm -rf "$lint_root"
}

trap cleanup_lint_root EXIT

settings="$root_dir/.qmllint.ini"
if [[ ! -f "$settings" ]]; then
  printf 'missing committed qmllint settings: %s\n' "$settings" >&2
  exit 1
fi
if [[ ! -x "$qt6_bin/qmllint" ]]; then
  printf 'qmllint not found at %s/qmllint\n' "$qt6_bin" >&2
  exit 1
fi

mkdir -p "$lint_root/qs" "$compiler_root"
ln -s "$omarchy_path/shell/Ui" "$lint_root/qs/Ui"
ln -s "$omarchy_path/shell/Commons" "$lint_root/qs/Commons"

compiler_checked_files=()
for file in "${qml_files[@]}"; do
  content="$(<"$file")"
  if [[ "$content" != *"import qs."*
        && "$content" != *"import Quickshell"*
        && "$content" != *"function "*
        && "$content" != *"property var"* ]]; then
    compiler_checked_files+=("$file")
  fi
done

if [[ "$apply_fix" -eq 1 ]]; then
  "$qt6_bin/qmllint" -I "$lint_root" -f -- "${qml_files[@]}"
fi
"$qt6_bin/qmllint" -I "$lint_root" -- "${qml_files[@]}"

# Run qmlsc compiler diagnostics only on fully declarative files with complete
# Qt metadata and no dynamically typed JavaScript function boundary.
cp -- "$settings" "$compiler_root/.qmllint.ini"
sed -i 's/^CompilerWarnings=.*/CompilerWarnings=warning/' \
  "$compiler_root/.qmllint.ini"
compiler_copies=()
for file in "${compiler_checked_files[@]}"; do
  destination="$compiler_root/$file"
  mkdir -p "$(dirname "$destination")"
  cp -- "$file" "$destination"
  compiler_copies+=("$destination")
done
if [[ "${#compiler_copies[@]}" -gt 0 ]]; then
  "$qt6_bin/qmllint" -I "$lint_root" -- "${compiler_copies[@]}"
fi
