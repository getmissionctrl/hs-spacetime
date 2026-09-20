#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
# Which reactor executable to build. Defaults to the person/event example.
exe="${1:-person-module-example}"
base="${exe%-example}" # person-module-example -> person-module
wasm32-wasi-cabal build -fwasm "exe:$exe"
# Locate the produced reactor wasm in dist-newstyle.
wasm="$(find dist-newstyle -name "$exe.wasm" -type f | head -1)"
[ -n "$wasm" ] || { echo "no wasm produced" >&2; exit 1; }
cp "$wasm" "$root/server/example/$base.wasm"
echo "built server/example/$base.wasm"
