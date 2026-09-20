#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/fixture-person"
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cargo build --release --target wasm32-unknown-unknown
wasm="$(ls target/wasm32-unknown-unknown/release/*.wasm | head -1)"
cd "$root/host"
cargo run --quiet --bin phase0-host -- --describe "$root/fixture-person/$wasm" \
  > "$root/golden/person.schema.bsatn"
echo "wrote golden/person.schema.bsatn ($(wc -c < "$root/golden/person.schema.bsatn") bytes)"
