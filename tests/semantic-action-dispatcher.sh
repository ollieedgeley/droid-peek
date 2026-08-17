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
if [[ "$#" != 6 || "$1" != "ollie.android" || "$2" != "action" ]]; then
  printf 'unexpected IPC arguments:' >&2
  printf ' <%s>' "$@" >&2
  printf '\n' >&2
  exit 2
fi
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" \
  >>"$FAKE_IPC_ARGUMENT_LOG"
action_id="$3"
action_argument="$4"
request_id="$5"
expires_at_unix_ms="$6"
case "$action_id" in
  omarchy-browser)
    [[ -z "$action_argument" ]] || exit 2
    ;;
  android-launch-app)
    [[ "$action_argument" == "com.example.notes" ]] || exit 2
    ;;
  *)
    printf 'unexpected action id: %s\n' "$action_id" >&2
    exit 2
    ;;
esac
if [[ ! "$request_id" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
  printf 'unsafe request id: %s\n' "$request_id" >&2
  exit 2
fi
if [[ ! "$expires_at_unix_ms" =~ ^[0-9]+$ ]]; then
  printf 'deadline is not a numeric IPC argument: %s\n' "$expires_at_unix_ms" >&2
  exit 2
fi
now_unix_ms="$(date +%s%3N)"
remaining_ms=$((expires_at_unix_ms - now_unix_ms))
if ((remaining_ms <= 0 || remaining_ms > 2000)); then
  printf 'deadline was not created 2000ms before IPC: %s (now %s)\n' \
    "$expires_at_unix_ms" "$now_unix_ms" >&2
  exit 2
fi
write_final_result() {
  if [[ -n "${FAKE_FINAL_RESULT:-}" ]]; then
    local result_dir="$XDG_RUNTIME_DIR/omarchy-android/action-results"
    mkdir -p "$result_dir"
    printf '%s\n' "$FAKE_FINAL_RESULT" >"$result_dir/$request_id"
  fi
}
if [[ "${FAKE_IPC_TIMEOUT:-false}" == "true" ]]; then
  trap '' TERM
  (
    sleep 2
    write_final_result
    sleep 2
    printf 'timed IPC survived its hard bound\n' >"$FAKE_TIMEOUT_LATE_CONTINUATION_LOG"
    sleep 2
  ) &
  timeout_worker_pid="$!"
  printf '%s\n%s\n' "$BASHPID" "$timeout_worker_pid" >"$FAKE_TIMEOUT_PID_FILE"
  printf '%s\n' "${FAKE_ACCEPT_RESULT:-false}"
  wait "$timeout_worker_pid"
  exit "${FAKE_ACTION_STATUS:-0}"
fi
write_final_result
printf '%s\n' "${FAKE_ACCEPT_RESULT:-false}"
exit "${FAKE_ACTION_STATUS:-0}"
EOF


cat >"$test_root/fallback" <<'EOF'
#!/usr/bin/env bash
if [[ -s "${FAKE_TIMEOUT_PID_FILE:-}" ]]; then
  while IFS= read -r timeout_pid; do
    if kill -0 "$timeout_pid" 2>/dev/null; then
      printf 'fallback ran while timed IPC process %s was still alive\n' "$timeout_pid" >&2
      exit 2
    fi
  done <"$FAKE_TIMEOUT_PID_FILE"
  date +%s%3N >"$FAKE_TIMEOUT_FALLBACK_AT_FILE"
fi
printf 'fallback\n' >>"$FAKE_FALLBACK_LOG"
EOF

chmod +x "$test_root/omarchy-shell" "$test_root/fallback"
export PATH="$test_root:$PATH"
export XDG_RUNTIME_DIR="$test_root/runtime"
export FAKE_FALLBACK_LOG="$test_root/fallback.log"
export FAKE_IPC_ARGUMENT_LOG="$test_root/ipc-arguments.log"
export FAKE_TIMEOUT_PID_FILE="$test_root/timeout.pid"
export FAKE_TIMEOUT_FALLBACK_AT_FILE="$test_root/timeout-fallback-at"
export FAKE_TIMEOUT_LATE_CONTINUATION_LOG="$test_root/timeout-late-continuation.log"
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

assert_ipc_count() {
  local expected="$1"
  local actual=0
  if [[ -f "$FAKE_IPC_ARGUMENT_LOG" ]]; then
    actual="$(wc -l <"$FAKE_IPC_ARGUMENT_LOG")"
  fi
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected %s bounded IPC calls, got %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_timeout_process_stopped() {
  local timeout_pid=
  local recorded_process=false
  if [[ -s "$FAKE_TIMEOUT_PID_FILE" ]]; then
    while IFS= read -r timeout_pid; do
      recorded_process=true
      if [[ ! "$timeout_pid" =~ ^[0-9]+$ ]]; then
        printf 'timed IPC process id was not recorded\n' >&2
        exit 1
      fi
      if kill -0 "$timeout_pid" 2>/dev/null; then
        printf 'timed IPC process %s was left running\n' "$timeout_pid" >&2
        exit 1
      fi
    done <"$FAKE_TIMEOUT_PID_FILE"
  fi
  if [[ "$recorded_process" != "true" ]]; then
    printf 'timed IPC process id was not recorded\n' >&2
    exit 1
  fi
}

assert_timeout_result_consumed() {
  local ipc_app ipc_method ipc_action ipc_argument logged_request_id ipc_deadline
  local timeout_request_id=
  while IFS='|' read -r \
    ipc_app ipc_method ipc_action ipc_argument logged_request_id ipc_deadline; do
    timeout_request_id="$logged_request_id"
  done <"$FAKE_IPC_ARGUMENT_LOG"

  local result_path="$XDG_RUNTIME_DIR/omarchy-android/action-results/$timeout_request_id"
  if [[ -e "$result_path" ]]; then
    printf 'accepted timed IPC result was not consumed\n' >&2
    exit 1
  fi
}
assert_hard_timeout_bound() {
  local started_at_ms="$1"
  local finished_at_ms="$2"
  local elapsed_ms=$((finished_at_ms - started_at_ms))
  if ((elapsed_ms < 2500 || elapsed_ms > 5000)); then
    printf 'hard IPC timeout completed after %sms instead of near 3000ms\n' \
      "$elapsed_ms" >&2
    exit 1
  fi

  if [[ -e "$FAKE_TIMEOUT_FALLBACK_AT_FILE" ]]; then
    printf 'accepted timed IPC unexpectedly ran desktop fallback\n' >&2
    exit 1
  fi
  if [[ -e "$FAKE_TIMEOUT_LATE_CONTINUATION_LOG" ]]; then
    printf 'timed IPC process continued work after its hard bound\n' >&2
    exit 1
  fi
}

assert_hard_ipc_wrapper() {
  if ! grep -Fq \
    'response="$(/usr/bin/timeout --signal=KILL 3 omarchy-shell ' \
    "$dispatcher"; then
    printf 'semantic IPC must use exactly /usr/bin/timeout --signal=KILL 3\n' >&2
    exit 1
  fi
}

FAKE_ACCEPT_RESULT=true FAKE_FINAL_RESULT=true \
  "$dispatcher" omarchy-browser '' fallback
assert_fallback_count 0
assert_ipc_count 1

FAKE_ACCEPT_RESULT=true FAKE_FINAL_RESULT=false \
  "$dispatcher" omarchy-browser '' fallback
assert_fallback_count 0

FAKE_ACCEPT_RESULT=true FAKE_FINAL_RESULT=unexpected \
  "$dispatcher" omarchy-browser '' fallback
assert_fallback_count 0

FAKE_ACCEPT_RESULT=false "$dispatcher" omarchy-browser '' fallback
assert_fallback_count 1

FAKE_ACCEPT_RESULT=true FAKE_ACTION_STATUS=1 \
  "$dispatcher" omarchy-browser '' fallback
assert_fallback_count 1

FAKE_ACCEPT_RESULT=true "$dispatcher" omarchy-browser '' fallback
assert_fallback_count 1

timeout_started_at_ms="$(date +%s%3N)"
FAKE_IPC_TIMEOUT=true FAKE_ACCEPT_RESULT=true FAKE_FINAL_RESULT=true \
  "$dispatcher" omarchy-browser '' fallback
timeout_finished_at_ms="$(date +%s%3N)"
assert_fallback_count 1
assert_ipc_count 7
assert_hard_timeout_bound "$timeout_started_at_ms" "$timeout_finished_at_ms"
assert_timeout_process_stopped
assert_timeout_result_consumed
assert_hard_ipc_wrapper

FAKE_ACCEPT_RESULT=true FAKE_FINAL_RESULT=true \
  "$dispatcher" android-launch-app com.example.notes fallback
assert_fallback_count 1
assert_ipc_count 8

if "$dispatcher" omarchy-browser '' 2>/dev/null; then
  printf 'dispatcher accepted a missing fallback\n' >&2
  exit 1
fi
assert_fallback_count 1
assert_ipc_count 8
