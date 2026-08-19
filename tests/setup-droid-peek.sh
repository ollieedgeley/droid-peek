#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
setup="$root_dir/scripts/setup-droid-peek"
cleanup="$root_dir/scripts/cleanup-droid-peek"
configurator="$root_dir/scripts/configure-droid-peek"
template="$root_dir/integrations/droid-peek.lua.example"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droid-peek-setup-test.XXXXXX")"

cleanup_test() {
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

prepare_case() {
  case_dir="$(mktemp -d "$test_root/case.XXXXXX")"
  host_root="$case_dir/host"
  fake_home="$case_dir/home"
  xdg_home="$case_dir/xdg"
  state_home="$case_dir/state"
  asset_dir="$case_dir/assets"
  shim_bin="$case_dir/bin"
  present_dir="$case_dir/present"
  plugin_json="$case_dir/plugins.json"
  omarchy_log="$case_dir/omarchy.log"
  pkg_add_log="$case_dir/pkg-add.log"
  enable_log="$case_dir/enable.log"
  curl_log="$case_dir/curl.log"
  sudo_log="$case_dir/sudo.log"
  systemctl_log="$case_dir/systemctl.log"
  checker="$case_dir/check-release-version"

  mkdir -p \
    "$host_root/usr/lib/modules/$(uname -r)" \
    "$host_root/etc/modules-load.d" \
    "$host_root/etc/modprobe.d" \
    "$host_root/sys/class/video4linux" \
    "$fake_home/.local/bin" \
    "$xdg_home/hypr" \
    "$state_home" \
    "$shim_bin" \
    "$present_dir" \
    "$asset_dir"

  printf 'linux\n' >"$host_root/usr/lib/modules/$(uname -r)/pkgbase"
  : >"$omarchy_log"
  : >"$pkg_add_log"
  : >"$enable_log"
  : >"$curl_log"
  : >"$sudo_log"
  : >"$systemctl_log"

  for pkg in android-tools avahi scrcpy qt6-multimedia v4l2loopback-dkms linux-headers; do
    : >"$present_dir/$pkg"
  done

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
  "pkg present")
    shift 2
    for pkg in "\$@"; do
      [[ -f "$present_dir/\$pkg" ]] || exit 1
    done
    exit 0
    ;;
  "pkg add")
    shift 2
    printf '%s\\n' "\$@" >>"$pkg_add_log"
    for pkg in "\$@"; do
      : >"$present_dir/\$pkg"
    done
    exit 0
    ;;
  "plugin list")
    [[ "\${3:-}" == --json ]] || exit 1
    cat "$plugin_json"
    ;;
  "plugin enable")
    printf '%s\\n' "\$*" >>"$enable_log"
    exit 0
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
  is-active|is-enabled)
    exit 0
    ;;
  enable)
    exit 0
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

  export HOME="$fake_home"
  export XDG_CONFIG_HOME="$xdg_home"
  export XDG_STATE_HOME="$state_home"
  export DROID_PEEK_HOST_ROOT="$host_root"
  export DROID_PEEK_HELPER_ASSET_DIR="$asset_dir"
  export DROID_PEEK_CHECK_RELEASE_VERSION="$checker"
  export PATH="$shim_bin:$PATH"
}

run_setup() {
  "$setup" "$@"
}

run_cleanup() {
  "$cleanup" "$@"
}

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
[[ "$setup_output" == *'install via omarchy pkg add: (none)'* ]] ||
  fail "dry-run did not report package plan"
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
[[ ! -s "$pkg_add_log" ]] || fail "dry-run invoked omarchy pkg add"
[[ ! -s "$curl_log" ]] || fail "dry-run invoked curl"
[[ ! -s "$sudo_log" ]] || fail "dry-run invoked sudo"
assert_absent "$fake_home/.local/bin/droid-peek-helper"
if ((real_modules_before == 0)); then
  assert_absent /etc/modules-load.d/droid-peek.conf
fi
if ((real_modprobe_before == 0)); then
  assert_absent /etc/modprobe.d/droid-peek.conf
fi

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
[[ ! -s "$pkg_add_log" ]] || fail "enabled plugin path invoked omarchy pkg add"

prepare_case
write_helper_asset "$asset_dir" "1.0.0"
printf '%s  %s\n' "$(printf '0%.0s' {1..64})" "$helper_filename" >"$asset_dir/SHA256SUMS"
if checksum_output="$(printf 'y\n' | run_setup 2>&1)"; then
  fail "checksum mismatch must fail closed"
fi
[[ "${checksum_output,,}" == *'checksum'* ]] ||
  fail "checksum failure did not mention checksum"
assert_absent "$fake_home/.local/bin/droid-peek-helper"
[[ ! -s "$pkg_add_log" ]] || fail "checksum failure installed packages"
assert_absent "$xdg_home/hypr/droid-peek.lua"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"

prepare_case
write_helper_asset "$asset_dir" "9.9.9"
write_sums "$asset_dir"
if version_output="$(printf 'y\n' | run_setup 2>&1)"; then
  fail "version mismatch must fail closed"
fi
[[ "$version_output" == *'9.9.9'* ]] ||
  fail "version failure did not report the helper version"
assert_absent "$fake_home/.local/bin/droid-peek-helper"
assert_absent "$xdg_home/hypr/droid-peek.lua"
assert_absent "$host_root/etc/modules-load.d/droid-peek.conf"

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
HOME="$fake_home" XDG_CONFIG_HOME="$xdg_home" "$configurator" install
cmp -s "$case_dir/existing-user.lua" "$xdg_home/hypr/droid-peek.lua" ||
  fail "configurator overwrote an existing user module"
[[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.droid-peek")'* ]] ||
  fail "configurator did not append the managed loader"

write_helper_asset "$asset_dir" "1.0.0"
write_sums "$asset_dir"
if ! setup_preserve_output="$(printf 'y\nn\n' | run_setup 2>&1)"; then
  printf '%s\n' "$setup_preserve_output" >&2
  fail "setup should succeed when fakes are healthy"
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
[[ ! -s "$pkg_add_log" ]] || fail "setup installed packages that were already present"
[[ ! -s "$enable_log" ]] || fail "setup enabled the plugin without confirmation"

prepare_case
mkdir -p "$xdg_home/hypr" "$fake_home/.local/bin" "$state_home/droid-peek"
printf 'user\n' >"$xdg_home/hypr/droid-peek.lua"
cat >"$xdg_home/hypr/bindings.lua" <<'EOF'
require("hypr.user")

-- Droid Peek plugin loader (managed)
require("hypr.droid-peek")
EOF
printf 'helper\n' >"$fake_home/.local/bin/droid-peek-helper"
printf 'state\n' >"$state_home/droid-peek/trusted-device.json"
printf 'v4l2loopback\n' >"$host_root/etc/modules-load.d/droid-peek.conf"
printf 'options v4l2loopback video_nr=42 card_label="Droid Peek" exclusive_caps=0\n' \
  >"$host_root/etc/modprobe.d/droid-peek.conf"
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

prepare_case
cat >"$plugin_json" <<'EOF'
[{"id":"ollieedgeley.droidpeek","name":"Droid Peek","kinds":["bar-widget"],"enabled":true}]
EOF
mkdir -p "$xdg_home/hypr" "$fake_home/.local/bin"
printf 'user\n' >"$xdg_home/hypr/droid-peek.lua"
printf 'helper\n' >"$fake_home/.local/bin/droid-peek-helper"
if cleanup_enabled="$(run_cleanup --dry-run 2>&1)"; then
  fail "enabled plugin must block cleanup"
fi
[[ "$cleanup_enabled" == *'enabled'* ]] ||
  fail "cleanup enabled-plugin failure did not mention enabled state"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_file "$xdg_home/hypr/droid-peek.lua"

prepare_case
mkdir -p "$xdg_home/hypr" "$fake_home/.local/bin" "$state_home/droid-peek"
printf 'user-owned\n' >"$xdg_home/hypr/droid-peek.lua"
cat >"$xdg_home/hypr/bindings.lua" <<'EOF'
require("hypr.user")

-- Droid Peek plugin loader (managed)
require("hypr.droid-peek")
EOF
printf 'helper\n' >"$fake_home/.local/bin/droid-peek-helper"
printf 'state\n' >"$state_home/droid-peek/trusted-device.json"
printf 'v4l2loopback\n' >"$host_root/etc/modules-load.d/droid-peek.conf"
if ! printf 'n\nn\nn\nn\ny\n' | run_cleanup >/dev/null; then
  fail "default cleanup should succeed and only remove the loader"
fi
printf 'user-owned\n' | cmp -s - "$xdg_home/hypr/droid-peek.lua" ||
  fail "default cleanup removed the user module"
assert_file "$fake_home/.local/bin/droid-peek-helper"
assert_file "$state_home/droid-peek/trusted-device.json"
assert_file "$host_root/etc/modules-load.d/droid-peek.conf"
if [[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.droid-peek")'* ]]; then
  fail "default cleanup left the managed loader in place"
fi
[[ "$(<"$xdg_home/hypr/bindings.lua")" == *'require("hypr.user")'* ]] ||
  fail "default cleanup rewrote user bindings"

setup_src="$(<"$setup")"
cleanup_src="$(<"$cleanup")"
[[ "$setup_src" != *pacman* && "$cleanup_src" != *pacman* ]] ||
  fail "setup/cleanup must not invoke the system package manager"
[[ "$setup_src" != *'modprobe -r'* && "$cleanup_src" != *'modprobe -r'* ]] ||
  fail "setup/cleanup must not unload v4l2loopback"
[[ "$setup_src" != *rmmod* && "$cleanup_src" != *rmmod* ]] ||
  fail "setup/cleanup must not unload v4l2loopback"
