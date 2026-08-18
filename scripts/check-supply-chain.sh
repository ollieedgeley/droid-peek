#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

cargo deny --version >/dev/null
cargo audit --version >/dev/null

printf '%s\n' '==> check dependency licenses, sources, bans, and advisories'
cargo deny \
  --manifest-path helper/Cargo.toml \
  --locked \
  check \
  --config helper/deny.toml \
  advisories bans licenses sources

printf '%s\n' '==> audit locked Rust dependencies'
cargo audit --file helper/Cargo.lock --deny warnings
