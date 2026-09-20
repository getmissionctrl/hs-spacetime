# Phase 1 — Milestone M-A Go / No-Go

**Verdict: GO.** ✅

The reusable `spacetime-server` Haskell library turns an author-provided `ModuleDef`
(schema bytes + typed reducer list) into a working, WASI-free SpacetimeDB module,
cross-compiled with `wasm32-wasi-cabal`, and all three example reducers round-trip
against a real local SpacetimeDB server.

## Evidence

- **Cross-compilation:** `bsatn` (incl. its `wide-word` dep) and `spacetime-server`
  (incl. the FFI `ABI` module + C shim) build under `wasm32-wasi-cabal` (GHC 9.12 wasm).
- **WASI-free reactor:** the example builds via cabal to a reactor, then Wizer-snapshot +
  `wasm-merge` strip leaves **zero `wasi_snapshot_preview1` imports** (`wasm-tools validate` OK).
  Its only imports are the nine `spacetime_10.0` host functions.
- **Live M-A (real server):** publish accepted; `record("carol")` + `record_n(3)` →
  `COUNT(event) == 2`; `record_n(0)` **rejected** with our exact `throwError` text
  ("count must be positive"), not a trap; `delete_all()` → `COUNT(event) == 0`;
  no trap-like lines in the server log.
  - Typed multi-reducer **dispatch by id** works (host maps reducer name→id via the
    embedded schema's alphabetical order: `delete_all=0, record=1, record_n=2`).
  - `ReducerContext.timestamp` observed live via `record` (row carries the micros).
  - `throwError` surfaces as a reducer error via `record_n(0)`.
  - `scan` + `delete` exercised live via `delete_all`.
- **Hermetic host (wasmtime, WASI OFF):** 5 tests green — context timestamp, error-not-trap,
  scan+delete, multi-chunk args >4096, and a row-larger-than-buffer (BUFFER_TOO_SMALL) case.
  Existing Phase-0 `host_tests` remain green (6).
- **Native units:** `87 examples, 0 failures` (82 client + 5 server dispatch). fourmolu clean.

## Deviations from the plan (all resolved)

The plan's `scan`/`delete` design assumed hermetic-stub semantics that did not match the
**real** SpacetimeDB v2.10 ABI. Three real bugs were found and fixed, then locked in by
making the hermetic host faithful:

1. **No-arg reducer hang (energy exhausted).** A no-arg reducer receives the INVALID
   `BytesSource` id `0`; `bytes_source_read(0, …)` returns `NO_SUCH_BYTES` (a *positive*
   errno) forever. The original `readSource` stopped only on `-1`, so `delete_all` looped
   until the energy budget was exhausted (~19 s). Fix: `readSource` short-circuits the
   `0` source and stops on any non-`0` return.
2. **`scan` row splitting.** `row_iter_bsatn_advance` returns rows as one concatenated
   BSATN batch (with a `BUFFER_TOO_SMALL` grow protocol), not one row per call. `Backend.scan`
   now returns the raw batch and the public `scan :: Decoder a -> TableId -> ReducerM [ByteString]`
   splits it into per-row byte slices using the row decoder (row boundaries are only knowable
   from the row type). `drainIter` implements the documented `0`/`-1`/`BUFFER_TOO_SMALL` protocol.
3. **`delete` relation encoding.** `datastore_delete_all_by_eq_bsatn` decodes `rel` as a
   `Vec<ProductValue>`; the FFI `delete` now wraps the single row as a 1-element vec
   (`[u32 count=1][row]`) instead of sending a bare row (which decoded as a bogus vec →
   `BSATN_DECODE_ERROR`).
4. **Reducer id ordering.** The golden schema orders reducers alphabetically
   (`delete_all, record, record_n`); the example's reducer list matches that order so
   name→id dispatch is correct (the plan's assumed source order was wrong).

The hermetic Track-B host was updated to mirror the real ABI (invalid-source `NO_SUCH_BYTES`,
`BUFFER_TOO_SMALL` on over-large rows, `Vec<ProductValue>` delete relation), so these
regressions are now covered by native/hermetic tests, not only the live check.

**Style:** server records use plain (unprefixed) fields with
`DuplicateRecordFields`/`OverloadedRecordDot`/`NoFieldSelectors` and `deriving stock (…, Generic)`,
per the project convention (mirrors `../vf-haskell`).
