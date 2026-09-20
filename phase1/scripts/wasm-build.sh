#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
# Cross-compile just the pure bsatn library (+ its wide-word dep) to wasm.
wasm32-wasi-cabal build bsatn
echo "BSATN_WASM_OK"
