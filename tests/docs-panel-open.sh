#!/usr/bin/env bash
set -euo pipefail

script_path="$(realpath -- "${BASH_SOURCE[0]}")"
root_dir="$(cd "$(dirname "$script_path")/.." && pwd -P)"
readme="$(<"$root_dir/README.md")"
use_and_configure="$(<"$root_dir/docs/how-to-use-and-configure.md")"
fix_problems="$(<"$root_dir/docs/how-to-fix-problems.md")"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ "$readme" != *'Super+Alt+A does the same from the'* ]] ||
  fail "README must not claim Super+Alt+A opens or closes like the bar icon"
[[ "$use_and_configure" != *'The desktop hotkey is Super+Alt+A'* ]] ||
  fail "Use and configure must not present Super+Alt+A as a desktop open hotkey"
[[ "$fix_problems" != *'The desktop hotkey must run'* ]] ||
  fail "Fix problems must not present a desktop toggle hotkey"
[[ "$readme" != *'phone mode'* && "$use_and_configure" != *'phone mode'* && "$fix_problems" != *'phone mode'* ]] ||
  fail "Public panel documentation must use Android mode, not phone mode"

[[ "$readme" == *'The bar icon opens or closes the panel.'* ]] ||
  fail "README must say the bar icon opens or closes the panel"
[[ "$readme" == *'Android mode is active only while the'* &&
  "$readme" == *'panel is open, **Android-mode shortcuts** is enabled, and the session is'* &&
  "$readme" == *'interactive. In that state, `Super+Alt+A` closes the panel'* ]] ||
  fail "README must define all three Android-mode conditions and close-only behavior"
[[ "$readme" == *'Your Android device. In the Omarchy bar.'* ]] ||
  fail "README must use Android device terminology"

[[ "$use_and_configure" == *'Click the Droid Peek bar icon to open the panel on that bar'\''s display.'* ]] ||
  fail "Use and configure must say the bar icon opens the panel"
[[ "$use_and_configure" == *'Click the icon again to close it.'* ]] ||
  fail "Use and configure must say the bar icon closes the panel"
[[ "$use_and_configure" == *'Android mode is active only when all three conditions are true:'* &&
  "$use_and_configure" == *'1. The panel is open.'* &&
  "$use_and_configure" == *'2. **Android-mode shortcuts** is enabled.'* &&
  "$use_and_configure" == *'3. The session is interactive.'* ]] ||
  fail "Use and configure must define all three Android-mode conditions"
[[ "$use_and_configure" == *'While Android mode is active, `Super+Alt+A` also closes it.'* ]] ||
  fail "Use and configure must keep Super+Alt+A close-only"
[[ "$use_and_configure" == *'Keep device connected'* ]] ||
  fail "Use and configure must use device terminology"
[[ "$use_and_configure" != *'omarchy-shell ollieedgeley.droidpeek toggle'* ]] ||
  fail "Use and configure must not recommend the plugin IPC toggle"

[[ "$fix_problems" == *'mode requires all three conditions: the panel is open'* &&
  "$fix_problems" == *'shortcuts** is enabled, and the session is interactive.'* &&
  "$fix_problems" == *'the panel only under those conditions.'* ]] ||
  fail "Fix problems must define all three Android-mode conditions and close-only behavior"
[[ "$fix_problems" == *'Android device'* ]] ||
  fail "Fix problems must use Android device terminology"
[[ "$fix_problems" != *'omarchy-shell ollieedgeley.droidpeek toggle'* ]] ||
  fail "Fix problems must not recommend the plugin IPC toggle"
