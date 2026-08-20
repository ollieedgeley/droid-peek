#!/usr/bin/env bash
set -euo pipefail

script_path="$(realpath -- "${BASH_SOURCE[0]}")"
root_dir="$(cd "$(dirname "$script_path")/.." && pwd -P)"
readme="$(<"$root_dir/README.md")"
configuration="$(<"$root_dir/docs/CONFIGURATION.md")"
troubleshooting="$(<"$root_dir/docs/TROUBLESHOOTING.md")"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ "$readme" != *'Super+Alt+A does the same from the'* ]] ||
  fail "README must not claim Super+Alt+A opens or closes like the bar icon"
[[ "$configuration" != *'The desktop hotkey is Super+Alt+A'* ]] ||
  fail "CONFIGURATION must not present Super+Alt+A as a desktop open hotkey"
[[ "$troubleshooting" != *'The desktop hotkey must run'* ]] ||
  fail "TROUBLESHOOTING must not present a desktop toggle hotkey"

[[ "$readme" == *'The bar icon opens or closes the panel.'* ]] ||
  fail "README must say the bar icon opens or closes the panel"
[[ "$readme" == *'Super+Alt+A closes'* && "$readme" == *'phone mode is active'* ]] ||
  fail "README must say Super+Alt+A closes only while phone mode is active"

[[ "$configuration" == *'The bar icon opens or closes the panel on that icon'\''s monitor.'* ]] ||
  fail "CONFIGURATION must say the bar icon opens or closes the panel"
[[ "$configuration" == *'Super+Alt+A'* && "$configuration" == *'closes the panel only while phone mode is active'* ]] ||
  fail "CONFIGURATION must say Super+Alt+A closes only while phone mode is active"
[[ "$configuration" == *'omarchy-shell ollieedgeley.droidpeek toggle'* ]] ||
  fail "CONFIGURATION must keep the warning not to use plugin IPC toggle"
[[ "$configuration" == *'| Super+Alt+A | Close Android panel | `android.close_panel` |'* ]] ||
  fail "CONFIGURATION table must still list Super+Alt+A as close-only"

[[ "$troubleshooting" == *'omarchy-shell ollieedgeley.droidpeek toggle'* ]] ||
  fail "TROUBLESHOOTING must keep the warning not to use plugin IPC toggle"
[[ "$troubleshooting" == *'Super+Alt+A'* && "$troubleshooting" == *'closes'* && "$troubleshooting" == *'phone mode is active'* ]] ||
  fail "TROUBLESHOOTING must say Super+Alt+A closes only while phone mode is active"
