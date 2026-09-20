#!/usr/bin/env bash
# Produce phase0/module/person-module.nowasi.wasm: a module with ZERO
# wasi_snapshot_preview1 imports that still runs in a WASI-OFF host.
#
# Pipeline (order matters):
#   1. build   — person-module.wasm (WASI reactor, built by build-module.sh)
#   2. wizer   — snapshot post-hs_init heap (wizer-init.sh); RTS init WASI calls
#                happen HERE, at snapshot time, not at deploy time.
#   3. stub    — compile wasi_stubs.c to a wasm module that EXPORTS the 18 WASI
#                funcs and IMPORTS its linear memory, then wasm-merge it over the
#                wizened module so the WASI imports resolve to the stubs and the
#                stubs share the primary module's memory.
#
# Why this order: the stubs are only a safety net (a WASI-off host links no
# WASI, so the imports must resolve to *something*). Because Wizer already ran
# init, the RTS never actually calls the stubs on the describe/reducer path — but
# they must exist and share memory in case any residual call fires. Stubbing
# BEFORE wizening would strip the very WASI shim Wizer needs to run init.
#
# wasm-merge namespace trick:
#   - wizened module named "env"                 -> stub's `env.memory` import
#                                                   resolves to primary memory
#   - stub module named "wasi_snapshot_preview1" -> primary's WASI imports
#                                                   resolve to stub exports
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
mod="$root/server/example"
src="${1:-$mod/person-module.wasm}"
out="${src%.wasm}.nowasi.wasm"

wizened="$(mktemp --suffix=.wasm)"
stubs="$(mktemp --suffix=.wasm)"
trap 'rm -f "$wizened" "$stubs"' EXIT

# 2. Wizer snapshot.
"$root/phase1/scripts/wizer-init.sh" "$src" "$wizened"

# 3a. Compile the WASI stub module.
#     -nostdlib / --no-entry: freestanding, no _start.
#     --export-dynamic: export every stub (they carry export_name attrs).
#     --import-memory: import linear memory (module "env") so the merge unifies
#                      it with the primary's memory rather than defining a second.
wasm32-wasi-clang -O2 -nostdlib \
  -Wl,--no-entry \
  -Wl,--export-dynamic \
  -Wl,--import-memory \
  "$root/server/cbits/wasi_stubs.c" -o "$stubs"

# 3b. Merge: resolve WASI imports against the stub exports, unify memory.
wasm-merge \
  "$wizened" env \
  "$stubs" wasi_snapshot_preview1 \
  --enable-bulk-memory \
  -o "$out"

echo "wrote $out"
