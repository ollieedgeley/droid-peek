#!/usr/bin/env bash
set -Eeuo pipefail

bindings_destination=""

has_loader() {
  [[ -f "$bindings_file" ]] || return 1
  if awk -v comment="$LOADER_COMMENT" -v loader="$LOADER_REQUIRE" '
    previous == comment && $0 == loader { found = 1 }
    { previous = $0 }
    END { exit found ? 0 : 1 }
  ' "$bindings_file"; then
    return 0
  fi
  return 1
}

resolve_bindings_destination() {
  bindings_destination=""
  if [[ -L "$bindings_file" ]]; then
    bindings_destination="$(readlink -f -- "$bindings_file" || true)"
    if [[ -z "$bindings_destination" || ! -e "$bindings_destination" ]]; then
      fail "bindings.lua symlink is broken. No changes were made."
    fi
    if [[ ! -f "$bindings_destination" || -L "$bindings_destination" ]]; then
      fail "bindings.lua symlink target is not a regular file. No changes were made."
    fi
    return 0
  fi
  if [[ -e "$bindings_file" && ! -f "$bindings_file" ]]; then
    fail "bindings.lua is not a regular file. No changes were made."
  fi
  bindings_destination="$bindings_file"
}

commit_bindings_temp() {
  local destination="$1"
  local temporary="$2"
  if [[ "${DROID_PEEK_INJECT_FAILURE:-}" == "loader-write" ]]; then
    fail "injected managed-loader write failure."
  fi
  if [[ -f "$destination" ]]; then
    chown --reference="$destination" "$temporary"
    chmod --reference="$destination" "$temporary"
  fi
  mv -- "$temporary" "$destination"
}

inspect_user_config() {
  if [[ -e "$user_module" ]]; then
    lua_action="preserve"
  else
    lua_action="copy"
  fi
  if has_loader; then
    loader_action="present"
  else
    loader_action="append"
  fi
}

install_user_config() {
  local temporary
  droid_peek_refresh_paths
  mkdir -p -- "$hypr_dir"
  if [[ ! -e "$user_module" ]]; then
    cp -- "$template" "$user_module"
  fi
  if [[ ! -e "$bindings_file" && ! -L "$bindings_file" ]]; then
    : >"$bindings_file"
  fi
  resolve_bindings_destination
  if has_loader; then
    return 0
  fi
  temporary="$(mktemp -- "$(dirname -- "$bindings_destination")/.droid-peek-bindings.XXXXXX")"
  droid_peek_register_temp "$temporary"
  {
    if [[ -f "$bindings_destination" ]]; then
      cat -- "$bindings_destination"
    fi
    printf '\n%s\n' "$LOADER_BLOCK"
  } >"$temporary"
  commit_bindings_temp "$bindings_destination" "$temporary"
}

remove_managed_loader() {
  local temporary
  droid_peek_refresh_paths
  [[ -e "$bindings_file" || -L "$bindings_file" ]] || return 0
  resolve_bindings_destination
  [[ -f "$bindings_destination" ]] || return 0
  temporary="$(mktemp -- "$(dirname -- "$bindings_destination")/.droid-peek-bindings.XXXXXX")"
  droid_peek_register_temp "$temporary"
  sed \
    -e '/^$/{N;/\n-- Droid Peek plugin loader (managed)$/{N;/^\n-- Droid Peek plugin loader (managed)\nrequire("hypr\.droid-peek")$/d;}}' \
    -e '/^-- Droid Peek plugin loader (managed)$/{N;/^-- Droid Peek plugin loader (managed)\nrequire("hypr\.droid-peek")$/d;}' \
    "$bindings_destination" >"$temporary"
  commit_bindings_temp "$bindings_destination" "$temporary"
}
