#!/usr/bin/env bash
# Capture the raw __describe_module__ schema of the probe fixture into the golden.
# Run inside `.#live` (provides `spacetime` + a Rust toolchain). Mirrors
# phase1/scripts/capture-golden.sh but targets the probe fixture.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
export RUSTUP_HOME="${HS_ST_RUSTUP_HOME:-/tmp/hs-st-rust/rustup}"
export CARGO_HOME="${HS_ST_CARGO_HOME:-/tmp/hs-st-rust/cargo}"
rustup default stable >/dev/null 2>&1 || true
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cd "$root/test/fixtures/probe"
cargo build --release --target wasm32-unknown-unknown
wasm="target/wasm32-unknown-unknown/release/hs_spacetime_probe.wasm"
cd "$root/phase0/host"
cargo run --quiet --bin phase0-host -- --describe "$root/test/fixtures/probe/$wasm" \
  > "$root/phase2/golden/probe.schema.bsatn"
echo "wrote phase2/golden/probe.schema.bsatn ($(wc -c < "$root/phase2/golden/probe.schema.bsatn") bytes)"
