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

phone_target_ipc="ollieedgeley.droidpeek"
phone_target_ipc+=" phone-target"

for retired in \
  actions.json \
  integrations/action-catalog.lua \
  integrations/config.example.lua \
  integrations/hyprland.lua \
  scripts/droid-peek-action; do
  if [[ -e "$retired" ]]; then
    printf 'retired phone-binding asset remains: %s\n' "$retired" >&2
    exit 1
  fi
done

for file in integrations/*.lua; do
  [[ "$file" == "integrations/phone-bindings.lua" ]] && continue
  content="$(<"$file")"
  if [[ "$content" == *"$phone_target_ipc"* ]]; then
    printf 'phone-target dispatch belongs in integrations/phone-bindings.lua: %s\n' "$file" >&2
    exit 1
  fi
done

for file in scripts/*; do
  [[ -f "$file" ]] || continue
  content="$(<"$file")"
  if [[ "$content" == *"$phone_target_ipc"* ]]; then
    printf 'shell scripts must not dispatch phone targets: %s\n' "$file" >&2
    exit 1
  fi
done

old_submap_dispatch='hyprctl([^[:alnum:]_-]+)dispatch([^[:alnum:]_-]+)'
old_submap_dispatch+='submap([^[:alnum:]_-]+)'
for file in ./*.qml qml/**/*.qml integrations/*.lua scripts/*; do
  [[ -f "$file" ]] || continue
  content="$(<"$file")"
  if [[ "$content" =~ $old_submap_dispatch ]]; then
    printf 'obsolete executable Hyprland submap dispatch: %s\n' "$file" >&2
    exit 1
  fi
done
