#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dist="$here/dist"
mkdir -p "$dist/vendor"
cd "$here"

wasm32-wasi-cabal build -fwasm exe:chat-web
wasm="$(wasm32-wasi-cabal list-bin -fwasm exe:chat-web)"
cp "$wasm" "$dist/chat-web.wasm"

libdir="$(wasm32-wasi-ghc --print-libdir)"
postlink="$libdir/post-link.mjs"
[ -f "$postlink" ] || postlink="$(find "$(dirname "$(command -v wasm32-wasi-ghc)")/.." -name post-link.mjs 2>/dev/null | head -n1)"
[ -n "$postlink" ] || { echo "ERROR: post-link.mjs not found; check the wasm32-wasi-ghc install" >&2; exit 1; }
node "$postlink" -i "$dist/chat-web.wasm" -o "$dist/ghc_wasm_jsffi.js"

cp "$here/web/index.html" "$dist/index.html"
cp "$here/web/run.mjs" "$dist/run.mjs"
cp "$here/web/vendor/browser_wasi_shim.mjs" "$dist/vendor/browser_wasi_shim.mjs"
echo "built $dist (chat-web.wasm, ghc_wasm_jsffi.js, index.html, run.mjs, vendor/)"
