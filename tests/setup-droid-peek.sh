#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
setup="$root_dir/scripts/setup-droid-peek"
cleanup="$root_dir/scripts/cleanup-droid-peek"
template="$root_dir/integrations/droid-peek.lua.example"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droid-peek-setup-test.XXXXXX")"
original_path="$PATH"

cleanup_test() {
  chmod -R u+rwx "$test_root" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup_test EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

assert_absent() {
  [[ ! -e "$1" ]] || fail "expected absent: $1"
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

snapshot_tree() {
  local path="$1"
  if [[ -d "$path" ]]; then
    find "$path" -printf '%P %s\n' | sort
  else
    printf 'missing\n'
  fi
}

write_exec() {
  local path="$1"
  cat >"$path"
  chmod +x "$path"
}

helper_filename='droid-peek-helper-1.0.0-x86_64-unknown-linux-gnu'

write_helper_asset() {
  local directory="$1"
  local version_output="$2"
  mkdir -p "$directory"
  write_exec "$directory/$helper_filename" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == --version ]]; then
  printf '%s\\n' '$version_output'
  exit 0
fi
exit 1
EOF
}

write_sums() {
  local directory="$1"
  local digest
  digest="$(sha256sum -- "$directory/$helper_filename" | awk '{print $1}')"
  printf '%s  %s\n' "$digest" "$helper_filename" >"$directory/SHA256SUMS"
}

write_loader() {
  local path="$1"
  mkdir -p "$(dirname -- "$path")"
  cat >"$path" <<'EOF'
require("hypr.user")

-- Droid Peek plugin loader (managed)
require("hypr.droid-peek")
EOF
}

prepare_case() {
  case_dir="$(mktemp -d "$test_root/case.XXXXXX")"
  host_root="$case_dir/host"
  fake_home="$case_dir/home"
  xdg_home="$case_dir/xdg"
  state_home="$case_dir/state"
  asset_dir="$case_dir/assets"
  shim_bin="$case_dir/bin"
  plugin_json="$case_dir/plugins.json"
  omarchy_log="$case_dir/omarchy.log"
  pkg_add_log="$case_dir/pkg-add.log"
  enable_log="$case_dir/enable.log"
  curl_log="$case_dir/curl.log"
  sudo_log="$case_dir/sudo.log"
  systemctl_log="$case_dir/systemctl.log"
  gum_log="$case_dir/gum.log"
  dkms_status_file="$case_dir/dkms-status"
  modinfo_vermagic_file="$case_dir/modinfo-vermagic"
  avahi_active_file="$case_dir/avahi-active"
  dkms_fail_file="$case_dir/dkms-fail"
  modinfo_fail_file="$case_dir/modinfo-fail"
  fuser_in_use_file="$case_dir/fuser-in-use"
  checker="$case_dir/check-release-version"
  kernel_release="$(uname -r)"

  mkdir -p \
    "$host_root/usr/lib/modules/$kernel_release/build" \
    "$host_root/etc/modules-load.d" \
    "$host_root/etc/modprobe.d" \
    "$host_root/sys/class/video4linux" \
    "$fake_home/.local/bin" \
    "$xdg_home/hypr" \
    "$state_home" \
    "$shim_bin" \
    "$asset_dir"

  printf 'linux\n' >"$host_root/usr/lib/modules/$kernel_release/pkgbase"
  : >"$omarchy_log"
  : >"$pkg_add_log"
  : >"$enable_log"
  : >"$curl_log"
  : >"$sudo_log"
  : >"$systemctl_log"
  : >"$gum_log"
  : >"$avahi_active_file"
  printf 'v4l2loopback/0.13.2, %s, x86_64: installed\n' "$kernel_release" >"$dkms_status_file"
  printf '%s SMP preempt libata\n' "$kernel_release" >"$modinfo_vermagic_file"

  cat >"$plugin_json" <<'EOF'
[{"id":"ollieedgeley.droidpeek","name":"Droid Peek","kinds":["bar-widget"],"enabled":false}]
EOF

  write_exec "$checker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  write_exec "$shim_bin/omarchy" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"$omarchy_log"
case "\${1:-} \${2:-}" in
  "pkg present"|"pkg add")
    printf '%s\\n' "\$*" >>"$pkg_add_log"
    exit 1
    ;;
  "plugin list")
    [[ "\${3:-}" == --json ]] || exit 1
    cat "$plugin_json"
    ;;
  "plugin enable")
    printf '%s\\n' "\$*" >>"$enable_log"
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF

  write_exec "$shim_bin/systemctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"$systemctl_log"
cmd="\${1:-}"
shift || true
if [[ "\${1:-}" == --quiet || "\${1:-}" == --now ]]; then
  shift || true
fi
case "\$cmd" in
  is-active)
    [[ -f "$avahi_active_file" ]] || exit 1
    exit 0
    ;;
  enable|start)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF

  write_exec "$shim_bin/sudo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"$sudo_log"
exec "\$@"
EOF

  write_exec "$shim_bin/modprobe" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$host_root/sys/class/video4linux/video42"
mkdir -p "$host_root/sys/devices/virtual/video4linux/video42"
mkdir -p "$host_root/sys/module/v4l2loopback"
mkdir -p "$host_root/dev"
printf 'Droid Peek\\n' >"$host_root/sys/class/video4linux/video42/name"
ln -sfn "$host_root/sys/devices/virtual/video4linux/video42" \\
  "$host_root/sys/class/video4linux/video42/device"
: >"$host_root/dev/video42"
exit 0
EOF

  write_exec "$shim_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  write_exec "$shim_bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"$curl_log"
exit 1
EOF

  write_exec "$shim_bin/dkms" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$dkms_fail_file" ]]; then
  exit 1
fi
cat "$dkms_status_file"
EOF

  write_exec "$shim_bin/modinfo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$modinfo_fail_file" ]]; then
  exit 1
fi
printf 'filename: /lib/modules/%s/updates/dkms/v4l2loopback.ko\\n' "$(uname -r)"
printf 'version: 0.13.2\\n'
printf 'vermagic:  %s' "\$(cat "$modinfo_vermagic_file")"
EOF

  write_exec "$shim_bin/gum" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"$gum_log"
exit 1
EOF

  write_exec "$shim_bin/fuser" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$fuser_in_use_file" ]]; then
  exit 0
fi
exit 1
EOF

  export HOME="$fake_home"
  export XDG_CONFIG_HOME="$xdg_home"
  export XDG_STATE_HOME="$state_home"
  export DROID_PEEK_HOST_ROOT="$host_root"
  export DROID_PEEK_HELPER_ASSET_DIR="$asset_dir"
  export DROID_PEEK_CHECK_RELEASE_VERSION="$checker"
  unset DROID_PEEK_INJECT_FAILURE
  export PATH="$shim_bin:$original_path"
}

isolate_without() {
  local hide="$1"
  local cmd src
  isolated_bin="$case_dir/isolated-bin"
  rm -rf "$isolated_bin"
  mkdir -p "$isolated_bin"
  cp -a "$shim_bin/." "$isolated_bin/"
  rm -f "$isolated_bin/$hide"
  for cmd in bash jq sha256sum install awk uname tr id readlink stat ln mkdir \
    cp mv chmod rm mktemp cat tee sed chown basename dirname cmp sort find \
    wc env git true false; do
    if [[ -e "$isolated_bin/$cmd" ]]; then
      continue
    fi
    src="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$src" && "$src" == /* ]]; then
      ln -s "$src" "$isolated_bin/$cmd"
    fi
  done
  export PATH="$isolated_bin"
}

run_setup() {
  "$setup" "$@"
}

run_cleanup() {
  "$cleanup" "$@"
}

assert_no_forbidden_invocations() {
  [[ ! -s "$pkg_add_log" ]] || fail "invoked omarchy pkg add"
  [[ ! -s "$enable_log" ]] || fail "invoked omarchy plugin enable"
  if grep -Eq '(^|[[:space:]])enable($|[[:space:]])' "$systemctl_log"; then
    fail "invoked systemctl enable"
  fi
  [[ ! -s "$gum_log" ]] || fail "invoked gum"
}

assert_scripts_forbid_host_mutation_tools() {
  local all_src
  all_src="$(cat "$setup" "$cleanup" "$root_dir/scripts/lib/"*.sh)"
  [[ "$all_src" != *pacman* ]] || fail "scripts must not invoke pacman"
  [[ "$all_src" != *'modprobe -r'* ]] || fail "scripts must not unload v4l2loopback"
  [[ "$all_src" != *rmmod* ]] || fail "scripts must not unload v4l2loopback"
  [[ "$all_src" != *'omarchy pkg add'* ]] || fail "scripts must not call omarchy pkg add"
  [[ "$all_src" != *'systemctl enable'* ]] || fail "scripts must not call systemctl enable"
}

seed_optional_state() {
  mkdir -p "$xdg_home/hypr" "$fake_home/.local/bin" "$state_home/droid-peek" \
    "$host_root/etc/modules-load.d" "$host_root/etc/modprobe.d"
  printf 'user-owned\n' >"$xdg_home/hypr/droid-peek.lua"
  write_loader "$xdg_home/hypr/bindings.lua"
  printf 'helper\n' >"$fake_home/.local/bin/droid-peek-helper"
  printf 'state\n' >"$state_home/droid-peek/trusted-device.json"
  printf 'v4l2loopback\n' >"$host_root/etc/modules-load.d/droid-peek.conf"
  printf 'options v4l2loopback video_nr=42 card_label="Droid Peek" exclusive_caps=0\n' \
    >"$host_root/etc/modprobe.d/droid-peek.conf"
}

assert_scripts_forbid_host_mutation_tools

prepare_case
before_host="$(snapshot_tree "$host_root")"
before_home="$(snapshot_tree "$fake_home")"
before_xdg="$(snapshot_tree "$xdg_home")"
real_modules_before=0
real_modprobe_before=0
[[ -e /etc/modules-load.d/droid-peek.conf ]] && real_modules_before=1
[[ -e /etc/modprobe.d/droid-peek.conf ]] && real_modprobe_before=1

setup_output="$(run_setup --dry-run)"
[[ "$setup_output" == *'Droid Peek setup plan'* ]] ||
  fail "dry-run did not print the setup plan"
[[ "$setup_output" != *'omarchy pkg add'* ]] ||
  fail "dry-run planned package installation"
[[ "$setup_output" == *"$helper_filename"* ]] ||
  fail "dry-run did not report helper asset"
[[ "$setup_output" == *'droid-peek.conf'* ]] ||
  fail "dry-run did not report V4L2 files"
[[ "$setup_output" == *'avahi-daemon.service'* ]] ||
  fail "dry-run did not report Avahi"
[[ "$setup_output" == *'droid-peek.lua'* ]] ||
  fail "dry-run did not report user Lua"
[[ "$setup_output" == *'Dry-run: no changes were made.'* ]] ||
  fail "dry-run did not declare that nothing changed"
[[ "$(snapshot_tree "$host_root")" == "$before_host" ]] ||
  fail "dry-run mutated the isolated host root"
[[ "$(snapshot_tree "$fake_home")" == "$before_home" ]] ||
  fail "dry-run mutated HOME"
[[ "$(snapshot_tree "$xdg_home")" == "$before_xdg" ]] ||
  fail "dry-run mutated XDG_CONFIG_HOME"
[[ ! -s "$curl_log" ]] || fail "dry-run invoked curl"
[[ ! -s "$sudo_log" ]] || fail "dry-run invoked sudo"
assert_no_forbidden_invocations
assert_absent "$fake_home/.local/bin/droid-peek-helper"
if ((real_modules_before == 0)); then
  assert_absent /etc/modules-load.d/droid-peek.conf
fi
if ((real_modprobe_before == 0)); then
  assert_absent /etc/modprobe.d/droid-peek.conf
fi

prepare_case
if tty_output="$(run_setup 2>&1)"; then
  fail "non-TTY setup without --yes must fail"
fi
[[ "$tty_output" == *'--yes'* ]] ||
  fail "non-TTY failure did not tell the user to pass --yes"
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_no_forbidden_invocations

prepare_case
cat >"$plugin_json" <<'EOF'
[{"id":"ollieedgeley.droidpeek","name":"Droid Peek","kinds":["bar-widget"],"enabled":true}]
EOF
before_host="$(snapshot_tree "$host_root")"
before_home="$(snapshot_tree "$fake_home")"
before_xdg="$(snapshot_tree "$xdg_home")"
if enabled_output="$(run_setup --dry-run 2>&1)"; then
  fail "enabled plugin must block setup"
fi
[[ "$enabled_output" == *'enabled'* ]] ||
  fail "enabled-plugin failure did not mention enabled state"
[[ "$(snapshot_tree "$host_root")" == "$before_host" ]] ||
  fail "enabled plugin path mutated the host root"
[[ "$(snapshot_tree "$fake_home")" == "$before_home" ]] ||
  fail "enabled plugin path mutated HOME"
[[ "$(snapshot_tree "$xdg_home")" == "$before_xdg" ]] ||
  fail "enabled plugin path mutated XDG_CONFIG_HOME"
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_no_forbidden_invocations

prepare_case
write_helper_asset "$asset_dir" "1.0.0"
printf '%s  %s\n' "$(printf '0%.0s' {1..64})" "$helper_filename" >"$asset_dir/SHA256SUMS"
if checksum_output="$(run_setup --yes 2>&1)"; then
  fail "checksum mismatch must fail closed"
fi
[[ "${checksum_output,,}" == *'checksum'* ]] ||
  fail "checksum failure did not mention checksum"
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_absent "$xdg_home/hypr/droid-peek.lua"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"
assert_no_forbidden_invocations

prepare_case
write_helper_asset "$asset_dir" "9.9.9"
write_sums "$asset_dir"
if version_output="$(run_setup --yes 2>&1)"; then
  fail "version mismatch must fail closed"
fi
[[ "$version_output" == *'9.9.9'* ]] ||
  fail "version failure did not report the helper version"
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_absent "$xdg_home/hypr/droid-peek.lua"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"

prepare_case
rm -rf "$host_root/usr/lib/modules/$(uname -r)/build"
if header_missing="$(run_setup --dry-run 2>&1)"; then
  fail "missing headers must refuse setup"
fi
[[ "$header_missing" == *'missing'* ]] ||
  fail "missing-header failure did not say missing"
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"

prepare_case
rm -rf "$host_root/usr/lib/modules/$(uname -r)/build"
printf 'not-a-directory\n' >"$host_root/usr/lib/modules/$(uname -r)/build"
if header_file="$(run_setup --dry-run 2>&1)"; then
  fail "non-directory headers must refuse setup"
fi
[[ "$header_file" == *'not a directory'* ]] ||
  fail "non-directory header failure did not say not a directory"

prepare_case
chmod a-r "$host_root/usr/lib/modules/$(uname -r)/build"
if header_unreadable="$(run_setup --dry-run 2>&1)"; then
  chmod u+rwx "$host_root/usr/lib/modules/$(uname -r)/build" 2>/dev/null || true
  fail "unreadable headers must refuse setup"
fi
chmod u+rwx "$host_root/usr/lib/modules/$(uname -r)/build"
[[ "$header_unreadable" == *'unreadable'* ]] ||
  fail "unreadable-header failure did not say unreadable"

prepare_case
isolate_without dkms
if dkms_missing="$(run_setup --dry-run 2>&1)"; then
  fail "missing dkms must refuse setup"
fi
[[ "$dkms_missing" == *'dkms is missing'* ]] ||
  fail "missing-dkms failure did not use the missing-dkms message"

prepare_case
: >"$dkms_fail_file"
if dkms_failed="$(run_setup --dry-run 2>&1)"; then
  fail "failed dkms status must refuse setup"
fi
[[ "$dkms_failed" == *'dkms status failed'* ]] ||
  fail "failed-dkms-status message was wrong"

prepare_case
: >"$dkms_status_file"
if dkms_empty="$(run_setup --dry-run 2>&1)"; then
  fail "empty dkms status must refuse setup"
fi
[[ "$dkms_empty" == *'no record'* ]] ||
  fail "empty-dkms-status message was wrong"

prepare_case
printf 'v4l2loopback/0.13.2, %s, x86_64: added\n' "$(uname -r)" >"$dkms_status_file"
if dkms_added="$(run_setup --dry-run 2>&1)"; then
  fail "dkms added-not-installed must refuse setup"
fi
[[ "$dkms_added" == *'installed'* ]] ||
  fail "uninstalled-dkms message was wrong"

prepare_case
: >"$modinfo_fail_file"
if modinfo_failed="$(run_setup --dry-run 2>&1)"; then
  fail "failed modinfo must refuse setup"
fi
[[ "$modinfo_failed" == *'modinfo failed'* ]] ||
  fail "failed-modinfo message was wrong"

prepare_case
: >"$modinfo_vermagic_file"
if vermagic_empty="$(run_setup --dry-run 2>&1)"; then
  fail "empty vermagic must refuse setup"
fi
[[ "$vermagic_empty" == *'vermagic is empty'* ]] ||
  fail "empty-vermagic message was wrong"

prepare_case
printf '!!bad\n' >"$modinfo_vermagic_file"
if vermagic_malformed="$(run_setup --dry-run 2>&1)"; then
  fail "malformed vermagic must refuse setup"
fi
[[ "$vermagic_malformed" == *'malformed'* ]] ||
  fail "malformed-vermagic message was wrong"

prepare_case
printf '%s-extra SMP\n' "$(uname -r)" >"$modinfo_vermagic_file"
if vermagic_prefix="$(run_setup --dry-run 2>&1)"; then
  fail "prefix vermagic must refuse setup"
fi
[[ "$vermagic_prefix" == *'prefix'* ]] ||
  fail "prefix-vermagic message was wrong"

prepare_case
printf '0.0.0 SMP\n' >"$modinfo_vermagic_file"
if vermagic_diff="$(run_setup --dry-run 2>&1)"; then
  fail "different vermagic must refuse setup"
fi
[[ "$vermagic_diff" == *'does not match'* ]] ||
  fail "different-vermagic message was wrong"

prepare_case
rm -f "$avahi_active_file"
if avahi_output="$(run_setup --dry-run 2>&1)"; then
  fail "inactive Avahi must refuse setup"
fi
[[ "$avahi_output" == *'avahi-daemon.service is not active'* ]] ||
  fail "inactive-Avahi message was wrong"
assert_absent "$fake_home/.local/bin/droid-peek-helper"

prepare_case
ln -s /tmp/not-droid-peek "$host_root/etc/modules-load.d/droid-peek.conf"
if v4l2_symlink="$(run_setup --dry-run 2>&1)"; then
  fail "V4L2 symlink must be a collision"
fi
[[ "$v4l2_symlink" == *'symlink'* ]] ||
  fail "V4L2 symlink collision did not mention symlink"

prepare_case
printf 'other\n' >"$host_root/etc/modprobe.d/droid-peek.conf"
if v4l2_content="$(run_setup --dry-run 2>&1)"; then
  fail "differing V4L2 content must be a collision"
fi
[[ "$v4l2_content" == *'unexpected contents'* ]] ||
  fail "V4L2 content collision did not mention contents"

prepare_case
mkdir -p "$xdg_home/hypr"
cat >"$xdg_home/hypr/droid-peek.lua" <<'EOF'
-- existing user configuration must win
return "user-owned"
EOF
cat >"$xdg_home/hypr/bindings.lua" <<'EOF'
-- user binding
require("hypr.user")
EOF
cp "$xdg_home/hypr/droid-peek.lua" "$case_dir/existing-user.lua"
write_helper_asset "$asset_dir" "1.0.0"
write_sums "$asset_dir"
if ! setup_preserve_output="$(run_setup --yes 2>&1)"; then
  printf '%s\n' "$setup_preserve_output" >&2
  fail "setup --yes should succeed"
fi
cmp -s "$case_dir/existing-user.lua" "$xdg_home/hypr/droid-peek.lua" ||
  fail "setup overwrote an existing user module"
[[ -x "$fake_home/.local/bin/droid-peek-helper" ]] ||
  fail "successful setup did not install the helper"
[[ "$(stat -c '%a' "$fake_home/.local/bin/droid-peek-helper")" == "755" ]] ||
  fail "installed helper mode is not 0755"
assert_file "$host_root/etc/modules-load.d/droid-peek.conf"
assert_file "$host_root/etc/modprobe.d/droid-peek.conf"
[[ "$(<"$host_root/etc/modules-load.d/droid-peek.conf")" == *'v4l2loopback'* ]] ||
  fail "modules-load file has the wrong contents"
[[ "$(<"$host_root/etc/modprobe.d/droid-peek.conf")" == *'card_label="Droid Peek"'* ]] ||
  fail "modprobe file is missing the Droid Peek label"
[[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.droid-peek")'* ]] ||
  fail "setup did not append the managed loader"
[[ "$setup_preserve_output" == *'omarchy plugin enable ollieedgeley.droidpeek'* ]] ||
  fail "setup did not print the enable command"
assert_no_forbidden_invocations
[[ ! -s "$curl_log" ]] || fail "local asset dir invoked curl"

if ! setup_again="$(run_setup --yes 2>&1)"; then
  printf '%s\n' "$setup_again" >&2
  fail "repeated setup --yes should be idempotent"
fi
cmp -s "$case_dir/existing-user.lua" "$xdg_home/hypr/droid-peek.lua" ||
  fail "repeated setup overwrote an existing user module"
loader_count="$(
  awk '
    previous == "-- Droid Peek plugin loader (managed)" &&
      $0 == "require(\"hypr.droid-peek\")" { count += 1 }
    { previous = $0 }
    END { print count + 0 }
  ' "$xdg_home/hypr/bindings.lua"
)"
[[ "$loader_count" == "1" ]] || fail "repeated setup duplicated the managed loader"

prepare_case
write_helper_asset "$asset_dir" "1.0.0"
write_sums "$asset_dir"
if ! inject_helper="$(DROID_PEEK_INJECT_FAILURE=after-helper run_setup --yes 2>&1)"; then
  :
else
  fail "injected helper failure must fail"
fi
[[ "$inject_helper" == *'Only the version-verified helper is present'* ]] ||
  fail "helper-stage failure did not report helper-only state"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"
assert_absent "$xdg_home/hypr/droid-peek.lua"
if ! run_cleanup --yes --remove-helper >/dev/null; then
  fail "cleanup should recover helper-only state"
fi
assert_absent "$fake_home/.local/bin/droid-peek-helper"

prepare_case
write_helper_asset "$asset_dir" "1.0.0"
write_sums "$asset_dir"
if ! inject_v4l2="$(DROID_PEEK_INJECT_FAILURE=after-v4l2 run_setup --yes 2>&1)"; then
  :
else
  fail "injected v4l2 failure must fail"
fi
[[ "$inject_v4l2" == *'Helper and V4L2 configuration are present'* ]] ||
  fail "v4l2-stage failure did not report helper+v4l2 state"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_file "$host_root/etc/modules-load.d/droid-peek.conf"
if [[ -f "$xdg_home/hypr/bindings.lua" && "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.droid-peek")'* ]]; then
  fail "v4l2-stage failure installed the loader"
fi
if ! run_cleanup --yes --remove-helper --remove-v4l2 >/dev/null; then
  fail "cleanup should recover helper+v4l2 state"
fi
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"
assert_absent "$host_root/etc/modprobe.d/droid-peek.conf"

prepare_case
write_helper_asset "$asset_dir" "1.0.0"
write_sums "$asset_dir"
if ! inject_loader="$(DROID_PEEK_INJECT_FAILURE=after-loader run_setup --yes 2>&1)"; then
  :
else
  fail "injected loader failure must fail"
fi
[[ "$inject_loader" == *'Helper, V4L2 configuration, and the managed loader are present'* ]] ||
  fail "loader-stage failure did not report all-three state"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_file "$host_root/etc/modules-load.d/droid-peek.conf"
[[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.droid-peek")'* ]] ||
  fail "loader-stage failure did not leave the loader"
assert_file "$xdg_home/hypr/droid-peek.lua"
if ! run_cleanup --yes --remove-helper --remove-v4l2 >/dev/null; then
  fail "cleanup should recover all-three state without deleting user Lua"
fi
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"
assert_file "$xdg_home/hypr/droid-peek.lua"
if [[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.droid-peek")'* ]]; then
  fail "all-three cleanup left the managed loader"
fi

prepare_case
seed_optional_state
before_host="$(snapshot_tree "$host_root")"
before_home="$(snapshot_tree "$fake_home")"
before_xdg="$(snapshot_tree "$xdg_home")"
before_state="$(snapshot_tree "$state_home")"
cleanup_dry="$(run_cleanup --dry-run)"
[[ "$cleanup_dry" == *'Droid Peek cleanup plan'* ]] ||
  fail "cleanup dry-run did not print the plan"
[[ "$cleanup_dry" == *'keep helper'* ]] ||
  fail "cleanup dry-run did not leave helper unchecked"
[[ "$cleanup_dry" == *'keep user module'* ]] ||
  fail "cleanup dry-run did not leave user Lua unchecked"
[[ "$cleanup_dry" == *'never remove shared packages or Avahi'* ]] ||
  fail "cleanup dry-run did not preserve shared packages"
[[ "$(snapshot_tree "$host_root")" == "$before_host" ]] ||
  fail "cleanup dry-run mutated the host root"
[[ "$(snapshot_tree "$fake_home")" == "$before_home" ]] ||
  fail "cleanup dry-run mutated HOME"
[[ "$(snapshot_tree "$xdg_home")" == "$before_xdg" ]] ||
  fail "cleanup dry-run mutated XDG_CONFIG_HOME"
[[ "$(snapshot_tree "$state_home")" == "$before_state" ]] ||
  fail "cleanup dry-run mutated XDG_STATE_HOME"
assert_no_forbidden_invocations

prepare_case
seed_optional_state
cleanup_dry_helper="$(run_cleanup --dry-run --remove-helper)"
[[ "$cleanup_dry_helper" == *'remove helper'* ]] ||
  fail "cleanup dry-run --remove-helper did not select the helper"
assert_file "$fake_home/.local/bin/droid-peek-helper"

prepare_case
cat >"$plugin_json" <<'EOF'
[{"id":"ollieedgeley.droidpeek","name":"Droid Peek","kinds":["bar-widget"],"enabled":true}]
EOF
seed_optional_state
if cleanup_enabled="$(run_cleanup --dry-run 2>&1)"; then
  fail "enabled plugin must block cleanup"
fi
[[ "$cleanup_enabled" == *'enabled'* ]] ||
  fail "cleanup enabled-plugin failure did not mention enabled state"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_file "$xdg_home/hypr/droid-peek.lua"

prepare_case
seed_optional_state
if ! run_cleanup --yes >/dev/null; then
  fail "bare cleanup --yes should succeed and only remove the loader"
fi
printf 'user-owned\n' | cmp -s - "$xdg_home/hypr/droid-peek.lua" ||
  fail "bare cleanup --yes removed the user module"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_file "$state_home/droid-peek/trusted-device.json"
assert_file "$host_root/etc/modules-load.d/droid-peek.conf"
if [[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.droid-peek")'* ]]; then
  fail "bare cleanup --yes left the managed loader in place"
fi
[[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.user")'* ]] ||
  fail "bare cleanup --yes rewrote user bindings"

prepare_case
seed_optional_state
if ! run_cleanup --yes --remove-helper >/dev/null; then
  fail "cleanup --yes --remove-helper should succeed"
fi
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_file "$xdg_home/hypr/droid-peek.lua"
assert_file "$host_root/etc/modules-load.d/droid-peek.conf"
assert_file "$state_home/droid-peek/trusted-device.json"
if [[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.droid-peek")'* ]]; then
  fail "cleanup --yes --remove-helper left the managed loader"
fi

prepare_case
seed_optional_state
if ! run_cleanup --yes --remove-v4l2 >/dev/null; then
  fail "cleanup --yes --remove-v4l2 should succeed"
fi
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"
assert_absent "$host_root/etc/modprobe.d/droid-peek.conf"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_file "$xdg_home/hypr/droid-peek.lua"

prepare_case
seed_optional_state
if ! run_cleanup --yes --remove-user-config >/dev/null; then
  fail "cleanup --yes --remove-user-config should succeed"
fi
assert_absent "$xdg_home/hypr/droid-peek.lua"
assert_file "$fake_home/.local/bin/droid-peek-helper"

prepare_case
seed_optional_state
if ! run_cleanup --yes --remove-state >/dev/null; then
  fail "cleanup --yes --remove-state should succeed"
fi
assert_absent "$state_home/droid-peek/trusted-device.json"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_file "$xdg_home/hypr/droid-peek.lua"

prepare_case
seed_optional_state
if ! run_cleanup --yes --remove-helper --remove-v4l2 --remove-user-config --remove-state >/dev/null; then
  fail "cleanup --yes with every optional should succeed"
fi
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"
assert_absent "$xdg_home/hypr/droid-peek.lua"
assert_absent "$state_home/droid-peek/trusted-device.json"

prepare_case
seed_optional_state
write_exec "$shim_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-x scrcpy" ]]; then
  printf '1\n'
  exit 0
fi
exit 1
EOF
if ! run_cleanup --yes >/dev/null; then
  fail "unrelated scrcpy must not block cleanup"
fi

prepare_case
seed_optional_state
write_exec "$shim_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-x droid-peek-helper" ]]; then
  printf '99999\n'
  exit 0
fi
exit 1
EOF
if helper_running="$(run_cleanup --yes 2>&1)"; then
  fail "a running helper must block cleanup"
fi
[[ "$helper_running" == *'helper'* ]] ||
  fail "running-helper cleanup failure did not mention the helper"
assert_file "$fake_home/.local/bin/droid-peek-helper"

prepare_case
seed_optional_state
mkdir -p "$host_root/dev"
: >"$host_root/dev/video42"
isolate_without fuser
if fuser_missing="$(run_cleanup --yes 2>&1)"; then
  fail "missing fuser must fail closed when the V4L2 device exists"
fi
[[ "$fuser_missing" == *'fuser'* ]] ||
  fail "missing-fuser failure did not mention fuser"
assert_file "$fake_home/.local/bin/droid-peek-helper"

prepare_case
if unknown_setup="$(run_setup --nope 2>&1)"; then
  fail "unknown setup option must fail"
fi
[[ "$unknown_setup" == *'usage:'* ]] ||
  fail "unknown setup option did not print usage"

prepare_case
if unknown_cleanup="$(run_cleanup --bogus 2>&1)"; then
  fail "unknown cleanup option must fail"
fi
[[ "$unknown_cleanup" == *'usage:'* ]] ||
  fail "unknown cleanup option did not print usage"
