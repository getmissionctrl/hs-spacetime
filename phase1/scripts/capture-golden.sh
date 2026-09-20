#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/server/fixture-event"
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cargo build --release --target wasm32-unknown-unknown
wasm="target/wasm32-unknown-unknown/release/phase1_fixture_event.wasm"
cd "$root/phase0/host"   # reuse the Phase-0 describe host binary
cargo run --quiet --bin phase0-host -- --describe "$root/server/fixture-event/$wasm" \
  > "$root/phase1/golden/event.schema.bsatn"
echo "wrote phase1/golden/event.schema.bsatn ($(wc -c < "$root/phase1/golden/event.schema.bsatn") bytes)"
