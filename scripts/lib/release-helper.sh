#!/usr/bin/env bash
set -Eeuo pipefail

release_version=""
helper_filename=""
helper_url=""
sums_url=""
helper_source=""

json_field() {
  jq -r "$1" "$root_dir/manifest.json"
}

inspect_helper() {
  release_version="$(json_field '.version')"
  [[ -n "$release_version" && "$release_version" != "null" ]] ||
    fail "manifest.json does not contain a release version."
  helper_filename="$HELPER_INSTALL_NAME-$release_version-x86_64-unknown-linux-gnu"
  if [[ -n "$asset_dir" ]]; then
    helper_source="$asset_dir/$helper_filename"
    helper_url="$helper_source"
    sums_url="$asset_dir/SHA256SUMS"
  else
    helper_url="https://github.com/ollieedgeley/droid-peek/releases/download/v${release_version}/$helper_filename"
    sums_url="https://github.com/ollieedgeley/droid-peek/releases/download/v${release_version}/SHA256SUMS"
    helper_source="$helper_url"
  fi
}

parse_sha256sums() {
  local file="$1"
  local expected_name="$2"
  local line digest name count=0
  [[ -s "$file" ]] || fail "SHA256SUMS is empty."
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || fail "SHA256SUMS contains a blank line."
    count=$((count + 1))
    if [[ "$line" =~ ^([0-9a-fA-F]{64})[[:space:]]+\*?([^[:space:]]+)$ ]]; then
      digest="${BASH_REMATCH[1]}"
      name="${BASH_REMATCH[2]}"
    else
      fail "SHA256SUMS line is malformed."
    fi
    [[ "$name" == "$expected_name" ]] ||
      fail "SHA256SUMS names '$name', expected '$expected_name'."
  done <"$file"
  [[ "$count" -eq 1 ]] || fail "SHA256SUMS must contain exactly one SHA-256 line, found $count."
  printf '%s\n' "$digest"
}

fetch_helper_assets() {
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/droid-peek-setup.XXXXXX")"
  if [[ -n "$asset_dir" ]]; then
    [[ -f "$asset_dir/$helper_filename" ]] ||
      fail "local helper asset not found: $asset_dir/$helper_filename"
    [[ -f "$asset_dir/SHA256SUMS" ]] || fail "local SHA256SUMS not found: $asset_dir/SHA256SUMS"
    cp -- "$asset_dir/$helper_filename" "$tmp_dir/$helper_filename"
    cp -- "$asset_dir/SHA256SUMS" "$tmp_dir/SHA256SUMS"
    return
  fi
  require_cmd curl
  curl -fsSL --output "$tmp_dir/$helper_filename" "$helper_url" ||
    fail "failed to download helper asset from $helper_url"
  curl -fsSL --output "$tmp_dir/SHA256SUMS" "$sums_url" ||
    fail "failed to download SHA256SUMS from $sums_url"
}

install_helper() {
  local expected actual version_output helper_dir temporary
  fetch_helper_assets
  expected="$(parse_sha256sums "$tmp_dir/SHA256SUMS" "$helper_filename")"
  actual="$(sha256sum -- "$tmp_dir/$helper_filename" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] ||
    fail "helper checksum mismatch. Expected $expected, got $actual. The helper was not installed."
  chmod 0755 "$tmp_dir/$helper_filename"
  version_output="$("$tmp_dir/$helper_filename" --version)" ||
    fail "helper --version failed. The helper was not installed."
  [[ "$version_output" == "$release_version" ]] ||
    fail "helper --version reported '$version_output', expected '$release_version'. The helper was not installed."
  helper_dir="$(dirname -- "$helper_path")"
  mkdir -p -- "$helper_dir"
  temporary="$(mktemp -- "$helper_dir/.droid-peek-helper.XXXXXX")"
  droid_peek_register_temp "$temporary"
  cp -- "$tmp_dir/$helper_filename" "$temporary"
  chmod 0755 "$temporary"
  mv -- "$temporary" "$helper_path"
  version_output="$("$helper_path" --version)" ||
    fail "installed helper --version failed at $helper_path."
  [[ "$version_output" == "$release_version" ]] ||
    fail "installed helper --version reported '$version_output', expected '$release_version'."
}
