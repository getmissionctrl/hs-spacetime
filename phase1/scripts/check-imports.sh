#!/usr/bin/env bash
# Assert a wasm module has ZERO wasi_snapshot_preview1 imports.
# Defaults to the nowasi module. Prints OK on success, fails otherwise.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
wasm="${1:-$root/server/example/person-module.nowasi.wasm}"

if [ ! -f "$wasm" ]; then
  echo "FAIL: $wasm not found (run stub-wasi.sh first)" >&2
  exit 1
fi

count="$(wasm-tools print "$wasm" | grep -c 'import "wasi_snapshot_preview1"' || true)"

if [ "$count" -ne 0 ]; then
  echo "FAIL: $wasm has $count wasi_snapshot_preview1 import(s):" >&2
  wasm-tools print "$wasm" | grep 'import "wasi_snapshot_preview1"' >&2
  exit 1
fi

echo "OK: $wasm has zero wasi_snapshot_preview1 imports"
