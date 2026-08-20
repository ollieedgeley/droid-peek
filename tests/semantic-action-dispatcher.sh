#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$root_dir/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/hyprland.sh
source "$root_dir/scripts/lib/hyprland.sh"
template="$root_dir/integrations/droid-peek.lua.example"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droid-peek-config-test.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

assert_exact_loader_count() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(
    awk '
      previous == "-- Droid Peek plugin loader (managed)" &&
        $0 == "require(\"hypr.droid-peek\")" { count += 1 }
      { previous = $0 }
      END { print count + 0 }
    ' "$path"
  )"
  [[ "$actual" == "$expected" ]] ||
    fail "expected $expected exact managed loader blocks in $path, got $actual"
}

xdg_home="$test_root/xdg"
fake_home="$test_root/home"
mkdir -p "$xdg_home/hypr" "$fake_home"

shim_bin="$test_root/bin"
chown_log="$test_root/chown.log"
mkdir -p "$shim_bin"
cat >"$shim_bin/chown" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CHOWN_LOG:?}"
exec /usr/bin/chown "$@"
EOF
chmod +x "$shim_bin/chown"

cat >"$xdg_home/hypr/bindings.lua" <<'EOF'
-- user binding before plugin block
require("hypr.user-bindings")

-- Droid Peek plugin loader (managed)
require("hypr.user-lookalike")
-- user binding after lookalike
EOF
cp "$xdg_home/hypr/bindings.lua" "$test_root/original-bindings.lua"

HOME="$fake_home" XDG_CONFIG_HOME="$xdg_home" install_user_config

[[ -f "$xdg_home/hypr/droid-peek.lua" ]] ||
  fail "install did not copy the user phone-binding template"
cmp -s "$template" "$xdg_home/hypr/droid-peek.lua" ||
  fail "first install did not copy the packaged template byte-for-byte"
[[ ! -e "$fake_home/.config/hypr/droid-peek.lua" ]] ||
  fail "XDG_CONFIG_HOME must take precedence over HOME/.config"
assert_exact_loader_count "$xdg_home/hypr/bindings.lua" 1
cp "$xdg_home/hypr/bindings.lua" "$test_root/installed-bindings.lua"

printf '\n-- user-owned edit after installation\n' >>"$xdg_home/hypr/droid-peek.lua"
cp "$xdg_home/hypr/droid-peek.lua" "$test_root/user-edited-phone-bindings.lua"

HOME="$fake_home" XDG_CONFIG_HOME="$xdg_home" install_user_config
cmp -s "$test_root/installed-bindings.lua" "$xdg_home/hypr/bindings.lua" ||
  fail "repeat install changed bindings.lua or duplicated the loader"
cmp -s "$test_root/user-edited-phone-bindings.lua" "$xdg_home/hypr/droid-peek.lua" ||
  fail "repeat install overwrote the user-owned phone bindings"
assert_exact_loader_count "$xdg_home/hypr/bindings.lua" 1

bindings_metadata_before="$(stat -c '%u:%g:%a' "$xdg_home/hypr/bindings.lua")"
HOME="$fake_home" \
  XDG_CONFIG_HOME="$xdg_home" \
  CHOWN_LOG="$chown_log" \
  PATH="$shim_bin:$PATH" \
  remove_managed_loader
cmp -s "$test_root/original-bindings.lua" "$xdg_home/hypr/bindings.lua" ||
  fail "uninstall changed user bindings or failed to remove only the managed block"
cmp -s "$test_root/user-edited-phone-bindings.lua" "$xdg_home/hypr/droid-peek.lua" ||
  fail "uninstall must preserve the user-owned phone bindings"
assert_exact_loader_count "$xdg_home/hypr/bindings.lua" 0
bindings_metadata_after="$(stat -c '%u:%g:%a' "$xdg_home/hypr/bindings.lua")"
[[ "$bindings_metadata_after" == "$bindings_metadata_before" ]] ||
  fail "uninstall replacement changed bindings.lua ownership, group, or mode"
[[ "$(wc -l <"$chown_log")" == "1" ]] ||
  fail "uninstall must preserve owner and group exactly once before replacement"
read -r chown_arguments <"$chown_log"
[[ "$chown_arguments" == "--reference=$xdg_home/hypr/bindings.lua "* ]] ||
  fail "uninstall must copy owner and group from bindings.lua"

HOME="$fake_home" XDG_CONFIG_HOME="$xdg_home" remove_managed_loader
cmp -s "$test_root/original-bindings.lua" "$xdg_home/hypr/bindings.lua" ||
  fail "repeat uninstall must be idempotent"

symlink_home="$test_root/symlink-home"
symlink_target="$test_root/symlinked-bindings.lua"
mkdir -p "$symlink_home/hypr"
cat >"$symlink_target" <<'EOF'
-- symlinked user binding
require("hypr.symlink-user")
EOF
ln -s "$symlink_target" "$symlink_home/hypr/bindings.lua"
HOME="$fake_home" XDG_CONFIG_HOME="$symlink_home" install_user_config
assert_exact_loader_count "$symlink_home/hypr/bindings.lua" 1
HOME="$fake_home" XDG_CONFIG_HOME="$symlink_home" remove_managed_loader
[[ -L "$symlink_home/hypr/bindings.lua" ]] ||
  fail "uninstall replaced the user bindings.lua symlink"
cat >"$test_root/expected-symlink-bindings.lua" <<'EOF'
-- symlinked user binding
require("hypr.symlink-user")
EOF
cmp -s "$test_root/expected-symlink-bindings.lua" "$symlink_target" ||
  fail "symlinked uninstall changed user bindings or retained the loader"

home_fallback="$test_root/home-fallback"
mkdir -p "$home_fallback/.config/hypr"
cat >"$home_fallback/.config/hypr/bindings.lua" <<'EOF'
-- independent HOME fixture
require("hypr.home-user")
EOF
cat >"$home_fallback/.config/hypr/droid-peek.lua" <<'EOF'
-- existing user configuration must win
return "user-owned"
EOF
cp \
  "$home_fallback/.config/hypr/droid-peek.lua" \
  "$test_root/existing-phone-bindings.lua"

unset XDG_CONFIG_HOME
HOME="$home_fallback" install_user_config
cmp -s \
  "$test_root/existing-phone-bindings.lua" \
  "$home_fallback/.config/hypr/droid-peek.lua" ||
  fail "install overwrote an existing HOME-based user configuration"
assert_exact_loader_count "$home_fallback/.config/hypr/bindings.lua" 1

HOME="$home_fallback" remove_managed_loader
cat >"$test_root/expected-home-bindings.lua" <<'EOF'
-- independent HOME fixture
require("hypr.home-user")
EOF
cmp -s \
  "$test_root/expected-home-bindings.lua" \
  "$home_fallback/.config/hypr/bindings.lua" ||
  fail "HOME-based uninstall did not preserve every user-owned byte"
cmp -s \
  "$test_root/existing-phone-bindings.lua" \
  "$home_fallback/.config/hypr/droid-peek.lua" ||
  fail "HOME-based uninstall removed the user-owned phone configuration"

broken_home="$test_root/broken-symlink"
mkdir -p "$broken_home/hypr"
ln -s "$test_root/missing-bindings.lua" "$broken_home/hypr/bindings.lua"
if (
  HOME="$fake_home"
  XDG_CONFIG_HOME="$broken_home"
  install_user_config
) 2>/dev/null; then
  fail "broken bindings.lua symlink must be refused"
fi
