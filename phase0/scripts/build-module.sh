#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/module/person-module.wasm"
cd "$root/module"
inc="$(dirname "$(find "$(wasm32-wasi-ghc --print-libdir)" -name HsFFI.h | head -1)")"
wasm32-wasi-clang -O2 -c cbits/spacetime_abi.c -o cbits/spacetime_abi.o -I"$inc"
wasm32-wasi-ghc \
  -no-hs-main -optl-mexec-model=reactor \
  -optl-Wl,--export=__describe_module__ \
  -optl-Wl,--export=__call_reducer__ \
  -optl-Wl,--export=_initialize \
  -optl-Wl,--export-memory \
  -O2 \
  Module.hs cbits/spacetime_abi.o \
  -o "$out"
echo "built $out"
