#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dispatcher="$root_dir/scripts/omarchy-android-action"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-android-action-test.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

cat >"$test_root/omarchy-shell" <<'EOF'
#!/usr/bin/env bash
request_id="${!#}"
if [[ ! "$request_id" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
  printf 'unsafe request id: %s\n' "$request_id" >&2
  exit 2
fi
if [[ -n "${FAKE_FINAL_RESULT:-}" ]]; then
  result_dir="$XDG_RUNTIME_DIR/omarchy-android/action-results"
  mkdir -p "$result_dir"
  printf '%s\n' "$FAKE_FINAL_RESULT" >"$result_dir/$request_id"
fi
printf '%s\n' "${FAKE_ACCEPT_RESULT:-false}"
exit "${FAKE_ACTION_STATUS:-0}"
EOF

cat >"$test_root/fallback" <<'EOF'
#!/usr/bin/env bash
printf 'fallback\n' >>"$FAKE_FALLBACK_LOG"
EOF

chmod +x "$test_root/omarchy-shell" "$test_root/fallback"
export PATH="$test_root:$PATH"
export XDG_RUNTIME_DIR="$test_root/runtime"
export FAKE_FALLBACK_LOG="$test_root/fallback.log"
export OMARCHY_ANDROID_ACTION_POLL_ATTEMPTS=1

assert_fallback_count() {
  local expected="$1"
  local actual=0
  if [[ -f "$FAKE_FALLBACK_LOG" ]]; then
    actual="$(wc -l <"$FAKE_FALLBACK_LOG")"
  fi
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected %s fallback calls, got %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

FAKE_ACCEPT_RESULT=true FAKE_FINAL_RESULT=true \
  "$dispatcher" omarchy-browser fallback
assert_fallback_count 0

FAKE_ACCEPT_RESULT=true FAKE_FINAL_RESULT=false \
  "$dispatcher" omarchy-browser fallback
assert_fallback_count 1

FAKE_ACCEPT_RESULT=true FAKE_FINAL_RESULT=unexpected \
  "$dispatcher" omarchy-browser fallback
assert_fallback_count 2

FAKE_ACCEPT_RESULT=false "$dispatcher" omarchy-browser fallback
assert_fallback_count 3

FAKE_ACCEPT_RESULT=true FAKE_ACTION_STATUS=1 \
  "$dispatcher" omarchy-browser fallback
assert_fallback_count 4

FAKE_ACCEPT_RESULT=true "$dispatcher" omarchy-browser fallback
assert_fallback_count 5

if "$dispatcher" omarchy-browser 2>/dev/null; then
  printf 'dispatcher accepted a missing fallback\n' >&2
  exit 1
fi
assert_fallback_count 5
