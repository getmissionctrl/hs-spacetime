#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
wasm32-wasi-cabal build -fwasm exe:person-module-example
# Locate the produced reactor wasm in dist-newstyle.
wasm="$(find dist-newstyle -name 'person-module-example.wasm' -type f | head -1)"
[ -n "$wasm" ] || { echo "no wasm produced" >&2; exit 1; }
cp "$wasm" "$root/server/example/person-module.wasm"
echo "built server/example/person-module.wasm"
