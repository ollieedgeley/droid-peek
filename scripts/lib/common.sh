#!/usr/bin/env bash
set -Eeuo pipefail

# Internal helpers sourced by setup-droid-peek and cleanup-droid-peek.

PLUGIN_ID='ollieedgeley.droidpeek'
CARD_LABEL='Droid Peek'
VIDEO_NR=42
HELPER_INSTALL_NAME='droid-peek-helper'
LOADER_COMMENT='-- Droid Peek plugin loader (managed)'
LOADER_REQUIRE='require("hypr.droid-peek")'
LOADER_BLOCK='-- Droid Peek plugin loader (managed)
require("hypr.droid-peek")'

_DROID_PEEK_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_DROID_PEEK_SCRIPTS_DIR="$(cd -- "$_DROID_PEEK_LIB_DIR/.." && pwd -P)"
root_dir="$(cd -- "$_DROID_PEEK_SCRIPTS_DIR/.." && pwd -P)"

droid_peek_stage='parse'
droid_peek_created_helper=0
droid_peek_created_v4l2=0
droid_peek_created_loader=0
dry_run=0
yes=0
tmp_dir=""
droid_peek_temps=()

host_root=""
config_home=""
hypr_dir=""
user_module=""
bindings_file=""
helper_path=""
modules_load_file=""
modprobe_file=""
video_dev=""
video_sysfs=""
module_sysfs=""
template=""

droid_peek_set_stage() {
  droid_peek_stage="$1"
}

droid_peek_partial_state_message() {
  if ((droid_peek_created_loader)); then
    printf '%s' "Helper, V4L2 configuration, and the managed loader are present. Recover with: ${_DROID_PEEK_SCRIPTS_DIR}/cleanup-droid-peek --yes --remove-helper --remove-v4l2"
  elif ((droid_peek_created_v4l2)); then
    printf '%s' "Helper and V4L2 configuration are present; the managed loader was not added. Recover with: ${_DROID_PEEK_SCRIPTS_DIR}/cleanup-droid-peek --yes --remove-helper --remove-v4l2"
  elif ((droid_peek_created_helper)); then
    printf '%s' "Only the version-verified helper is present. Recover with: ${_DROID_PEEK_SCRIPTS_DIR}/cleanup-droid-peek --yes --remove-helper"
  else
    printf '%s' "No Droid Peek state was created."
  fi
}

fail() {
  printf '%s\n' "$*" >&2
  if ((droid_peek_created_helper || droid_peek_created_v4l2 || droid_peek_created_loader)); then
    printf '%s\n' "$(droid_peek_partial_state_message)" >&2
  fi
  exit 1
}

droid_peek_on_err() {
  local status=$?
  trap - ERR
  printf '%s\n' "Droid Peek failed during stage: ${droid_peek_stage}." >&2
  printf '%s\n' "$(droid_peek_partial_state_message)" >&2
  exit "$status"
}

droid_peek_cleanup_temps() {
  local t
  if [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]]; then
    rm -rf -- "$tmp_dir"
  fi
  tmp_dir=""
  if ((${#droid_peek_temps[@]})); then
    for t in "${droid_peek_temps[@]}"; do
      rm -f -- "$t"
    done
  fi
  droid_peek_temps=()
}

droid_peek_register_temp() {
  droid_peek_temps+=("$1")
}

droid_peek_install_entry_traps() {
  trap droid_peek_on_err ERR
  trap droid_peek_cleanup_temps EXIT
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

host_path() {
  printf '%s%s' "${host_root:-}" "$1"
}

run_privileged() {
  if [[ -n "${host_root:-}" ]] || [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

droid_peek_refresh_paths() {
  host_root="${DROID_PEEK_HOST_ROOT:-}"
  config_home="${XDG_CONFIG_HOME:-${HOME:?HOME is required}/.config}"
  hypr_dir="$config_home/hypr"
  user_module="$hypr_dir/droid-peek.lua"
  bindings_file="$hypr_dir/bindings.lua"
  helper_path="$HOME/.local/bin/$HELPER_INSTALL_NAME"
  modules_load_file="$(host_path /etc/modules-load.d/droid-peek.conf)"
  modprobe_file="$(host_path /etc/modprobe.d/droid-peek.conf)"
  video_dev="$(host_path /dev/video${VIDEO_NR})"
  video_sysfs="$(host_path /sys/class/video4linux/video${VIDEO_NR})"
  module_sysfs="$(host_path /sys/module/v4l2loopback)"
  template="$root_dir/integrations/droid-peek.lua.example"
}

droid_peek_confirm() {
  local prompt="$1"
  if ((dry_run)) || ((yes)); then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    fail "standard input is not a terminal; re-run with --yes. No changes were made."
  fi
  if ! command -v gum >/dev/null 2>&1; then
    fail "install gum. No changes were made."
  fi
  if gum confirm -- "$prompt"; then
    return 0
  fi
  fail "cancelled. No changes were made."
}

droid_peek_inject_after() {
  local stage="$1"
  if [[ "${DROID_PEEK_INJECT_FAILURE:-}" == "$stage" ]]; then
    fail "injected failure after ${stage}."
  fi
}

plugin_list_json() {
  require_cmd omarchy
  omarchy plugin list --json
}

plugin_is_enabled() {
  local plugins
  plugins="$(plugin_list_json)" || fail "could not query plugin state; is the Omarchy shell running?"
  if jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and .enabled == true)' >/dev/null <<<"$plugins"; then
    return 0
  fi
  return 1
}

plugin_is_discovered() {
  local plugins
  plugins="$(plugin_list_json)" || fail "could not query plugin state; is the Omarchy shell running?"
  if jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null <<<"$plugins"; then
    return 0
  fi
  return 1
}

refuse_if_plugin_enabled() {
  if plugin_is_enabled; then
    fail "plugin $PLUGIN_ID is enabled. Disable it with 'omarchy plugin disable $PLUGIN_ID' before changing the host. No changes were made."
  fi
}

check_architecture() {
  local machine
  machine="$(uname -m)"
  [[ "$machine" == "x86_64" ]] ||
    fail "unsupported architecture '$machine'. The first Droid Peek release supports only x86_64. No changes were made."
}

check_kernel() {
  local release pkgbase_file pkgbase
  release="$(uname -r)"
  pkgbase_file="$(host_path /usr/lib/modules/"$release"/pkgbase)"
  if [[ ! -f "$pkgbase_file" ]]; then
    fail "could not determine the running kernel package (missing $pkgbase_file). The first Droid Peek release supports only Arch's linux kernel with matching linux-headers. Boot that kernel, then re-run setup. No changes were made."
  fi
  pkgbase="$(tr -d '[:space:]' <"$pkgbase_file")"
  [[ "$pkgbase" == "linux" ]] ||
    fail "the running kernel '$release' is supplied by '$pkgbase', not Arch's linux package. The first Droid Peek release supports only the stock linux kernel with linux-headers. Boot that kernel, or install matching headers for this kernel manually, then re-run setup. No changes were made."
}

run_check_release_version() {
  local checker="${DROID_PEEK_CHECK_RELEASE_VERSION:-$_DROID_PEEK_SCRIPTS_DIR/dev/check-release-version}"
  [[ -x "$checker" ]] || fail "missing release check: $checker"
  "$checker" || fail "release version check failed; no changes were made."
}

helper_is_running() {
  if pgrep -x droid-peek-helper >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

scrcpy_is_helper_descendant() {
  local helper_pids scrcpy_pids pid walk ppid helper
  helper_pids=()
  scrcpy_pids=()
  if ! helper_is_running; then
    return 1
  fi
  mapfile -t helper_pids < <(pgrep -x droid-peek-helper || true)
  mapfile -t scrcpy_pids < <(pgrep -x scrcpy || true)
  ((${#helper_pids[@]})) || return 1
  ((${#scrcpy_pids[@]})) || return 1
  for pid in "${scrcpy_pids[@]}"; do
    walk="$pid"
    while [[ "$walk" =~ ^[0-9]+$ && "$walk" -gt 1 ]]; do
      [[ -r "/proc/$walk/status" ]] || break
      ppid="$(awk '/^PPid:/ { print $2; exit }' "/proc/$walk/status")"
      [[ "$ppid" =~ ^[0-9]+$ ]] || break
      for helper in "${helper_pids[@]}"; do
        if [[ "$ppid" == "$helper" ]]; then
          return 0
        fi
      done
      walk="$ppid"
    done
  done
  return 1
}
