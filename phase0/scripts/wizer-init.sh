#!/usr/bin/env bash
# Snapshot the post-`hs_init` heap with Wizer.
#
# The GHC RTS runs its init path (which CALLS several WASI functions:
# environ_sizes_get/environ_get, clock_time_get, fd_write, ...) inside
# `_initialize`. Wizer runs `_initialize` once here, WITH a real WASI shim
# (--allow-wasi), and captures the resulting linear memory as data segments.
# The deployed module then starts already-initialized and never re-runs
# `hs_init`, so those WASI calls never happen at runtime.
#
# Wizer CONSUMES `_initialize` (removes the export) after snapshotting; the
# module still exports memory/__describe_module__/__call_reducer__. The Track B
# host's `initialize()` no-ops when `_initialize` is absent, which is correct:
# the RTS state is already baked into the snapshot.
#
# NOTE: the 18 wasi_snapshot_preview1 IMPORTS remain after this step — snapshot
# does not remove imports. stub-wasi.sh strips them next.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
in="${1:-$root/module/person-module.wasm}"
out="${2:-$root/module/person-module.wizened.wasm}"

wizer \
  --allow-wasi \
  --init-func _initialize \
  --wasm-bulk-memory true \
  "$in" -o "$out"

echo "wizened $in -> $out"
