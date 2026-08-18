#!/usr/bin/env bash
set -euo pipefail

script_path="$(realpath -- "${BASH_SOURCE[0]}")"
root_dir="$(cd "$(dirname "$script_path")/.." && pwd -P)"
panel="$(<"$root_dir/Panel.qml")"
preview="$(<"$root_dir/qml/components/PhonePreview.qml")"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ "$panel" == *'readonly property var popupPalette: Color.popups'* &&
   "$panel" == *'readonly property color contentForeground: popupPalette.text'* ]] ||
  fail "Panel content foreground must use the live popup text role"
[[ "$panel" == *'readonly property color contentBackground: popupPalette.background'* ]] ||
  fail "Panel content background must use the live popup background role"

foreground_bindings=0
while IFS= read -r line; do
  [[ "$line" == *'foreground: root.contentForeground'* ]] &&
    foreground_bindings=$((foreground_bindings + 1))
done <"$root_dir/Panel.qml"
[[ "$foreground_bindings" -ge 9 ]] ||
  fail "every panel child and manual pairing control must use the popup foreground"

[[ "$preview" == *'import qs.Commons'* ]] ||
  fail "PhonePreview must import the live Omarchy palette"
[[ "$preview" == *'readonly property var popupPalette: Color.popups'* ]] ||
  fail "PhonePreview must retain a live popup palette binding"
[[ "$preview" == *'property color foreground: popupPalette.text'* ]] ||
  fail "PhonePreview foreground fallback must use the popup text role"
[[ "$preview" == *'property color background: popupPalette.background'* ]] ||
  fail "PhonePreview background fallback must use the popup background role"

for file in "$root_dir"/*.qml "$root_dir"/qml/components/*.qml; do
  content="$(<"$file")"
  [[ "$content" != *'colors.toml'* && "$content" != *'shell.toml'* ]] ||
    fail "visual QML must not parse theme files: $file"
done

for file in "$root_dir"/qml/state/*.qml "$root_dir"/qml/*.js; do
  content="$(<"$file")"
  [[ "$content" != *'Color.'* && "$content" != *'Style.'* ]] ||
    fail "non-visual state and lifecycle code must not own theme policy: $file"
done
