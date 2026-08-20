#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
apply_fix=0

if [[ "${1:-}" == "--fix" ]]; then
  apply_fix=1
  shift
fi

cd "$root_dir"
manifest=(--manifest-path helper/Cargo.toml)

if [[ "$apply_fix" -eq 1 ]]; then
  cargo fmt "${manifest[@]}"
  cargo clippy "${manifest[@]}" --all-targets --all-features --locked \
    --fix --allow-dirty --allow-staged
  cargo fmt "${manifest[@]}"
fi

cargo fmt "${manifest[@]}" -- --check
cargo clippy "${manifest[@]}" --all-targets --all-features --locked -- -D warnings
