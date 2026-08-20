#!/usr/bin/env bash
set -euo pipefail

script_path="$(realpath -- "${BASH_SOURCE[0]}")"
root_dir="$(cd "$(dirname "$script_path")/.." && pwd -P)"
workflow_path="$root_dir/.github/workflows/release-helper.yml"
workflow="$(<"$workflow_path")"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

shellcheck_command=""
in_public_script_step=false
while IFS= read -r line; do
  if [[ "$line" == "      - name: ShellCheck public scripts" ]]; then
    in_public_script_step=true
    continue
  fi
  if $in_public_script_step && [[ "$line" == "      - name: "* ]]; then
    break
  fi
  if $in_public_script_step; then
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ "$trimmed" == shellcheck\ * ]]; then
      [[ -z "$shellcheck_command" ]] ||
        fail "release workflow public-script step must contain exactly one ShellCheck command"
      shellcheck_command="$trimmed"
    fi
  fi
done <<<"$workflow"

[[ -n "$shellcheck_command" ]] ||
  fail "release workflow public-script ShellCheck command is missing"

read -r -a command_parts <<<"$shellcheck_command"
follow_sources=false
script_source_path=false
separator_index=-1
for ((index = 1; index < ${#command_parts[@]}; index++)); do
  case "${command_parts[index]}" in
    -x)
      follow_sources=true
      ;;
    -P)
      if ((index + 1 < ${#command_parts[@]})) &&
        [[ "${command_parts[index + 1]}" == SCRIPTDIR ]]; then
        script_source_path=true
      fi
      ;;
    --)
      separator_index=$index
      break
      ;;
  esac
done

$follow_sources && $script_source_path ||
  fail "release workflow public-script ShellCheck command must include -x and -P SCRIPTDIR to follow sources relative to each script"

((separator_index >= 0)) ||
  fail "release workflow public-script ShellCheck command must separate options from script paths with --"

expected_scripts=(
  scripts/setup-droid-peek
  scripts/cleanup-droid-peek
)
actual_scripts=("${command_parts[@]:separator_index + 1}")
for script in "${actual_scripts[@]}"; do
  [[ "$script" != scripts/lib/* ]] ||
    fail "release workflow must not pass sourced libraries as standalone ShellCheck inputs: shared variables are defined and consumed across source boundaries, so declared source directives must cover libraries transitively from the public entry points"
done
[[ "${actual_scripts[*]}" == "${expected_scripts[*]}" ]] ||
  fail "release workflow ShellCheck must cover exactly: ${expected_scripts[*]}"
