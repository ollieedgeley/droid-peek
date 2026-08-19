#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
report="$(mktemp "${TMPDIR:-/tmp}/droid-peek-coverage.XXXXXX.json")"
trap 'rm -f "$report"' EXIT

command -v jq >/dev/null || {
  printf 'jq is required for focused coverage checks\n' >&2
  exit 1
}
cargo llvm-cov --version >/dev/null

if [[ -z "${LLVM_COV:-}" ]] && command -v llvm-cov >/dev/null; then
  export LLVM_COV
  LLVM_COV="$(command -v llvm-cov)"
fi
if [[ -z "${LLVM_PROFDATA:-}" ]] && command -v llvm-profdata >/dev/null; then
  export LLVM_PROFDATA
  LLVM_PROFDATA="$(command -v llvm-profdata)"
fi

cd "$root_dir"
cargo llvm-cov \
  --manifest-path helper/Cargo.toml \
  --locked \
  --all-targets \
  --json \
  --summary-only \
  --output-path "$report"

check_file() {
  local file="$1"
  local minimum="$2"
  local actual
  actual="$(jq -er --arg suffix "/helper/src/$file" '
    [.data[0].files[] | select(.filename | endswith($suffix)) | .summary.lines.percent]
    | if length == 1 then .[0] else error("missing or duplicate coverage file") end
  ' "$report")"
  printf '%-16s %6.2f%% (minimum %s%%)\n' "$file" "$actual" "$minimum"
  jq -e --arg suffix "/helper/src/$file" --argjson minimum "$minimum" '
    [.data[0].files[] | select(.filename | endswith($suffix)) | .summary.lines.percent]
    | length == 1 and .[0] >= $minimum
  ' "$report" >/dev/null
}

printf '%s\n' '==> enforce focused Rust line coverage'
check_file actions.rs 90
check_file input.rs 85
check_file pairing.rs 90
check_file persistence.rs 90
check_file preferences.rs 90
check_file protocol.rs 75
check_file runtime.rs 85
