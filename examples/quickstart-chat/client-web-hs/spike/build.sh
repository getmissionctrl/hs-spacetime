#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
wasm32-wasi-cabal build exe:spike
wasm="$(wasm32-wasi-cabal list-bin exe:spike)"
libdir="$(wasm32-wasi-ghc --print-libdir)"
postlink="$libdir/post-link.mjs"
[ -f "$postlink" ] || postlink="$(find "$(dirname "$(command -v wasm32-wasi-ghc)")/.." -name post-link.mjs 2>/dev/null | head -n1)"
cp "$wasm" ./spike.wasm
node "$postlink" -i ./spike.wasm -o ./ghc_wasm_jsffi.js
echo "built spike.wasm + ghc_wasm_jsffi.js (post-link: $postlink)"
