#!/usr/bin/env bash
set -Eeuo pipefail

v4l2_action=""
modules_load_content='v4l2loopback'
modprobe_content="options v4l2loopback video_nr=${VIDEO_NR} card_label=\"${CARD_LABEL}\" exclusive_caps=0"

file_has_content() {
  local path="$1"
  local expected="$2"
  [[ -f "$path" ]] && [[ "$(<"$path")" == "$expected" || "$(<"$path")" == "$expected"$'\n' ]]
}

video_name() {
  local name_file="$video_sysfs/name"
  [[ -f "$name_file" ]] || return 1
  tr -d '\n' <"$name_file"
}

is_loopback_sysfs() {
  local sysfs="$1"
  local resolved driver
  [[ -e "$sysfs/device" ]] || return 1
  resolved="$(readlink -f -- "$sysfs/device" 2>/dev/null || true)"
  [[ "$resolved" == *"/virtual/video4linux/"* ]] && return 0
  driver="$(readlink -f -- "$sysfs/device/driver" 2>/dev/null || true)"
  [[ "$driver" == *"v4l2loopback"* ]]
}

other_loopback_exists() {
  local entry
  [[ -d "$(host_path /sys/class/video4linux)" ]] || return 1
  for entry in "$(host_path /sys/class/video4linux)"/video*; do
    [[ -e "$entry" ]] || continue
    [[ "$(basename -- "$entry")" == "video$VIDEO_NR" ]] && continue
    if is_loopback_sysfs "$entry"; then
      return 0
    fi
  done
  return 1
}

fuser_device_in_use() {
  local path="$1"
  local status=0
  if [[ ! -e "$path" ]]; then
    return 1
  fi
  command -v fuser >/dev/null 2>&1 ||
    fail "fuser is required to inspect $path. No changes were made."
  if [[ ! -r "$path" ]]; then
    fail "cannot inspect $path. No changes were made."
  fi
  fuser -s -- "$path" 2>/dev/null || status=$?
  if ((status == 0)); then
    return 0
  fi
  if ((status == 1)); then
    return 1
  fi
  fail "could not determine whether $path is in use. No changes were made."
}

module_loaded() {
  [[ -d "$module_sysfs" ]]
}

v4l2_collision() {
  printf '%s\n' "$1" >&2
  printf '%s\n' "No V4L2 files were changed. Reboot into a host without a colliding loopback device, or recover the existing /dev/video$VIDEO_NR configuration manually, then re-run setup." >&2
  exit 1
}

inspect_v4l2_file() {
  local path="$1"
  local expected="$2"
  if [[ -L "$path" ]]; then
    v4l2_collision "V4L2 collision: $path is a symlink."
  fi
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    v4l2_collision "V4L2 collision: $path is not a regular file."
  fi
  if ! file_has_content "$path" "$expected"; then
    v4l2_collision "V4L2 collision: $path has unexpected contents."
  fi
}

check_kernel_headers() {
  local release build_dir
  release="$(uname -r)"
  build_dir="$(host_path /usr/lib/modules/"$release"/build)"
  if [[ ! -e "$build_dir" ]]; then
    fail "kernel headers are missing: $build_dir is not present. Install linux-headers matching the running kernel, then re-run setup. No changes were made."
  fi
  if [[ ! -d "$build_dir" ]]; then
    fail "kernel headers path is not a directory: $build_dir. Install linux-headers matching the running kernel, then re-run setup. No changes were made."
  fi
  if [[ ! -r "$build_dir" ]]; then
    fail "kernel headers are unreadable: $build_dir. Install linux-headers matching the running kernel, then re-run setup. No changes were made."
  fi
}

check_dkms_v4l2loopback() {
  local release status_output modinfo_output vermagic first_field
  release="$(uname -r)"
  command -v dkms >/dev/null 2>&1 ||
    fail "dkms is missing. Install v4l2loopback-dkms and matching kernel headers, then re-run setup. No changes were made."

  status_output=""
  if ! status_output="$(dkms status -m v4l2loopback -k "$release" 2>/dev/null)"; then
    fail "dkms status failed for v4l2loopback on kernel $release. No changes were made."
  fi
  [[ -n "$status_output" ]] ||
    fail "dkms status returned no record for v4l2loopback on kernel $release. No changes were made."
  if [[ "$status_output" != *installed* ]]; then
    fail "dkms does not report an installed v4l2loopback build for kernel $release. No changes were made."
  fi

  command -v modinfo >/dev/null 2>&1 ||
    fail "required command not found: modinfo. No changes were made."
  modinfo_output=""
  if ! modinfo_output="$(modinfo -k "$release" v4l2loopback 2>/dev/null)"; then
    fail "modinfo failed for v4l2loopback on kernel $release. No changes were made."
  fi
  vermagic="$(awk '/^vermagic:/ { sub(/^vermagic:[[:space:]]*/, ""); print; exit }' <<<"$modinfo_output")"
  [[ -n "$vermagic" ]] ||
    fail "v4l2loopback vermagic is empty. No changes were made."
  first_field="${vermagic%%[[:space:]]*}"
  [[ -n "$first_field" ]] ||
    fail "v4l2loopback vermagic is empty. No changes were made."
  if [[ ! "$first_field" =~ ^[0-9] ]]; then
    fail "v4l2loopback vermagic is malformed: '$vermagic'. No changes were made."
  fi
  if [[ "$first_field" != "$release" ]]; then
    if [[ "$first_field" == "$release"* || "$release" == "$first_field"* ]]; then
      fail "v4l2loopback vermagic '$first_field' is only a prefix match for kernel $release. No changes were made."
    fi
    fail "v4l2loopback vermagic '$first_field' does not match kernel $release. No changes were made."
  fi
}

inspect_v4l2() {
  inspect_v4l2_file "$modules_load_file" "$modules_load_content"
  inspect_v4l2_file "$modprobe_file" "$modprobe_content"

  if module_loaded; then
    if other_loopback_exists; then
      v4l2_collision "V4L2 collision: another v4l2loopback device is already present."
    fi
    if [[ ! -e "$video_dev" || ! -d "$video_sysfs" ]]; then
      v4l2_collision "V4L2 collision: v4l2loopback is loaded but /dev/video$VIDEO_NR is missing."
    fi
    if ! is_loopback_sysfs "$video_sysfs"; then
      v4l2_collision "V4L2 collision: /dev/video$VIDEO_NR exists but is not a v4l2loopback device."
    fi
    local name
    name="$(video_name || true)"
    if [[ "$name" != "$CARD_LABEL" ]]; then
      v4l2_collision "V4L2 collision: /dev/video$VIDEO_NR is labelled '${name:-unknown}', not '$CARD_LABEL'."
    fi
    if fuser_device_in_use "$video_dev"; then
      v4l2_collision "V4L2 collision: /dev/video$VIDEO_NR is in use."
    fi
    v4l2_action="write-files-only"
    return
  fi

  if [[ -e "$video_dev" || -d "$video_sysfs" ]]; then
    v4l2_collision "V4L2 collision: /dev/video$VIDEO_NR exists while v4l2loopback is not loaded."
  fi
  if other_loopback_exists; then
    v4l2_collision "V4L2 collision: another v4l2loopback device is already present."
  fi
  v4l2_action="write-and-load"
}

write_managed_root_file() {
  local path="$1"
  local content="$2"
  local dir temporary
  dir="$(dirname -- "$path")"
  if [[ -n "$host_root" ]]; then
    mkdir -p -- "$dir"
    temporary="$(mktemp -- "$dir/.droid-peek.XXXXXX")"
    droid_peek_register_temp "$temporary"
    printf '%s\n' "$content" >"$temporary"
    if [[ "${DROID_PEEK_INJECT_FAILURE:-}" == "v4l2-write" ]]; then
      fail "injected privileged write failure."
    fi
    mv -- "$temporary" "$path"
    return
  fi
  run_privileged mkdir -p -- "$dir"
  temporary="$(run_privileged mktemp -- "$dir/.droid-peek.XXXXXX")"
  droid_peek_register_temp "$temporary"
  printf '%s\n' "$content" | run_privileged tee -- "$temporary" >/dev/null
  if [[ "${DROID_PEEK_INJECT_FAILURE:-}" == "v4l2-write" ]]; then
    fail "injected privileged write failure."
  fi
  run_privileged mv -- "$temporary" "$path"
}

provision_v4l2() {
  if ! file_has_content "$modules_load_file" "$modules_load_content"; then
    write_managed_root_file "$modules_load_file" "$modules_load_content"
  fi
  if ! file_has_content "$modprobe_file" "$modprobe_content"; then
    write_managed_root_file "$modprobe_file" "$modprobe_content"
  fi
  if [[ "$v4l2_action" == "write-and-load" ]]; then
    run_privileged modprobe v4l2loopback
  fi
}

remove_managed_root_file() {
  local path="$1"
  local expected="$2"
  if [[ -L "$path" ]]; then
    fail "refusing to remove $path: it is a symlink. No V4L2 files were changed."
  fi
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    fail "refusing to remove $path: it is not a regular file. No V4L2 files were changed."
  fi
  if ! file_has_content "$path" "$expected"; then
    fail "refusing to remove $path: contents are not Droid Peek-managed. No V4L2 files were changed."
  fi
  if [[ -n "$host_root" ]] || [[ "$(id -u)" -eq 0 ]]; then
    rm -f -- "$path"
    return
  fi
  run_privileged rm -f -- "$path"
}

remove_droid_peek_v4l2() {
  remove_managed_root_file "$modules_load_file" "$modules_load_content"
  remove_managed_root_file "$modprobe_file" "$modprobe_content"
}

require_video_idle() {
  if [[ ! -e "$video_dev" ]]; then
    return 0
  fi
  if fuser_device_in_use "$video_dev"; then
    fail "/dev/video$VIDEO_NR still has users. Close the panel before cleanup. No changes were made."
  fi
}
