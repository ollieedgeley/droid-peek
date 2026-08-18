#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

command -v sg >/dev/null || {
  printf 'ast-grep (sg) is required for architecture checks\n' >&2
  exit 1
}

printf '%s\n' '==> test architecture rules'
sg test --skip-snapshot-tests
printf '%s\n' '==> scan architecture ownership'
sg scan --error=unused-suppression

shopt -s globstar nullglob
for file in ./*.qml qml/**/*.qml; do
  [[ "$file" == "./Panel.qml" ]] && continue
  content="$(<"$file")"
  if [[ "$content" == *'helperProcess.write('* ]]; then
    printf 'QML helper writes belong in Panel.qml: %s\n' "$file" >&2
    exit 1
  fi
done

semantic_ipc="ollie.android"
semantic_ipc+=" action"

for file in integrations/*.lua; do
  [[ "$file" == "integrations/hyprland.lua" ]] && continue
  content="$(<"$file")"
  if [[ "$content" == *'omarchy-android-action'* || "$content" == *"$semantic_ipc"* ]]; then
    printf 'Lua semantic dispatch belongs in integrations/hyprland.lua: %s\n' "$file" >&2
    exit 1
  fi
done

for file in scripts/*; do
  [[ "$file" == "scripts/omarchy-android-action" ]] && continue
  [[ -f "$file" ]] || continue
  content="$(<"$file")"
  if [[ "$content" == *"$semantic_ipc"* ]]; then
    printf 'Shell semantic dispatch belongs in scripts/omarchy-android-action: %s\n' "$file" >&2
    exit 1
  fi
done
