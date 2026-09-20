# Haskell SpacetimeDB Server Runtime — Phase 1 Design

**Date:** 2026-09-20
**Status:** Design approved; spec under review
**Branch:** `phase1-server-runtime` (stacked on `phase0-haskell-module`)
**Predecessor:** [Phase 0 design](2026-09-20-haskell-spacetimedb-module-phase0-design.md) — feasibility GO.

## Background

Phase 0 proved (with a live GO against SpacetimeDB v2.10) that a GHC-compiled
wasm module can act as a SpacetimeDB server module: it links the `spacetime_10.0`
ABI, runs as a WASI-free reactor, publishes, and round-trips a reducer. But the
Phase 0 module is a one-off: it embeds a hand-captured golden schema and dumps it
verbatim, and its single `add` reducer is hardcoded with manual byte marshalling.

Phase 1 turns that one-off into a **reusable server-runtime library** and, in
doing so, cracks the dependency-toolchain problem Phase 0 dodged. It is the
foundation for Phase 2 (schema derived from Haskell types) and beyond, on the
road to full parity with the Rust/C#/TS server SDKs.

### Phase 0 findings this design builds on

- **The C-shim FFI indirection is mandatory.** GHC's wasm FFI always emits
  imports into module `env`, so Haskell cannot reference `spacetime_10.0`
  imports directly. A thin C shim (`shim_*` wrappers with `import_module`
  attributes) is required.
- **`__preinit__*` describers** exist for Rust/TS modules but are irrelevant to
  our approach (we stream provided schema bytes).
- **`bytes_source_read` returns `-1` together with the final chunk** (and frees
  the source). Byte harvesting must happen on every read, stopping iff `rc == -1`.
- **`wide-word` (a BSATN codec dep) is not in the bare wasm GHC package db.**
  Phase 0 inlined a string codec to avoid it. Phase 1 must instead build via
  `wasm32-wasi-cabal` so the real dependency closure cross-compiles.
- **Wizer snapshots `hs_init`** (consuming `_initialize`); then WASI imports are
  stubbed/merged away. This pipeline carries over unchanged.

## Scope

**Phase 1 delivers** a reusable `spacetime-server` library (wasm-targetable,
pure deps) that turns an author-provided `ModuleDef` (schema bytes + a typed
reducer list) into a working SpacetimeDB module, plus the generalized cabal→
wasm→Wizer→stub build pipeline.

**In scope:**
- Cracking `wasm32-wasi-cabal`: a real library-with-dependencies builds to a
  wasm reactor. This unlocks reuse of the repo's existing, property-tested BSATN
  codec and its `Identity`/`ConnectionId`/`Timestamp`/`TimeDuration` types.
- A package restructure extracting the BSATN modules into a shared pure library
  (so the wasm server lib does not pull the client's networking deps).
- The generalized C-shim layer (the `shim_*` pattern + the `spacetime_10.0`
  imports the runtime uses).
- The two required exports implemented once in the library.
- **Typed, multi-reducer dispatch** by ABI reducer id.
- A **restricted `ReducerM`** monad + a `ReducerContext` (decoded sender
  `Identity`, optional `ConnectionId`, `Timestamp`). Being in `ReducerM` is
  itself the table-op capability — no separate token is threaded.
- BytesSource/BytesSink streaming marshalling (corrected `-1`-with-final-chunk).
- errno / error-sink handling; correct handling of unit-returning reducers.
- Raw-ish table-op primitives (`tableId`, `insert`, `scan`, delete).
- `console_log`-backed logging.
- The generalized build/Wizer/stub scripts.

**Out of scope (deferred):**
- Type-derived schema — Phase 2. Schema is author-provided as bytes here.
- Typed per-table accessors (`ctx.db.person.insert(Person{..})`) — Phase 3.
- Indexes, primary keys, auto-inc, scheduled reducers, lifecycle hooks,
  procedures, HTTP, RLS — Phase 4.

## Approach decisions

1. **Build via `wasm32-wasi-cabal`.** Phase 0's hand-compile hit the wall at the
   first non-boot dependency. Cabal cross-compiles the dependency closure. GHC
   reactor flags, exports, and the C-shim `c-sources` are declared in the
   `.cabal` file. (Hand-managing a wasm package-db is rejected.)
2. **Reducers as an explicit positional list.** The author exports
   `ModuleDef { schemaBytes, reducers = [r0, r1, …] }`; the runtime's single
   `__call_reducer__` indexes `reducers` by the ABI reducer id. Each entry
   bundles its BSATN arg-decoder + handler (existential). This mirrors the
   positional-id ABI and keeps the list consistent with the schema's reducer
   order. (A typeclass/registration-monad alternative is rejected — more magic,
   no benefit.)
3. **Restricted `ReducerM`, hand-rolled over `IO` — no effects library.**
   Handlers run in `ReducerM`, a newtype over `ReducerContext -> IO (Either Text
   a)` (equivalently `ReaderT ReducerContext (ExceptT Text IO)`). `IO` sits at
   the base (table ops are FFI calls), but there is **no exported `MonadIO`/
   `liftIO`**: the only bridge from `IO` (`prim :: IO a -> ReducerM a`) is
   library-internal, and effects reach users only through exported primitives
   (`insert`, `scan`, `throwError`, `ask`). This makes non-deterministic `IO`
   *unrepresentable* in a reducer, enforcing SpacetimeDB's determinism rule at
   the type level. No effects library (`polysemy`/`effectful`/`fused-effects`/
   `cleff`): the effect set is tiny and fixed, and every dependency is a
   wasm-cross-compilation liability; `transformers` (a GHC boot package) or a
   hand-written instance suffices. (`MonadIO`-polymorphic handlers are rejected
   — strictly more permissive, inviting the non-determinism we must forbid.)

## Architecture

### Package layout (one `hs-spacetime` package, multiple cabal components)

```
library bsatn            -- extracted, pure: SpacetimeDB.BSATN.{Decoder,Encoder,Types}
                         --   deps: base, bytestring, text, wide-word
library hs-spacetime      -- existing client; now depends on `bsatn` (networking deps unchanged)
library spacetime-server  -- NEW, wasm-targetable: SpacetimeDB.Server(.Runtime/.Context/.Table)
                         --   c-sources: cbits/spacetime_abi.c ; install-includes: spacetime_abi.h
                         --   deps: base, bytestring, text, bsatn   (NO networking)
executable person-module-example  -- the example reactor module (ghc-options: reactor + exports);
                                  --   depends on spacetime-server; provides the foreign-export glue + ModuleDef
```

The server library never depends on the client library, so
`wasm32-wasi-cabal build exe:person-module-example` cross-compiles only the pure
closure (`bsatn` + `spacetime-server` + base/bytestring/text/wide-word).

### Developer-facing API (`SpacetimeDB.Server`)

```haskell
data ModuleDef = ModuleDef
  { schemaBytes :: ByteString     -- author-provided in P1; Phase 2 generates it
  , reducers    :: [Reducer]      -- positional: list index = ABI reducer id
  }

-- existential in the arg type; the smart ctor is the only way to build one
reducer :: Decoder a -> (a -> ReducerM ()) -> Reducer

data ReducerContext = ReducerContext
  { sender       :: Identity
  , connectionId :: Maybe ConnectionId  -- all-zero words → Nothing
  , timestamp    :: Timestamp           -- micros
  }
-- Table ops are ReducerM primitives that hit the ambient transaction directly;
-- being in ReducerM is the capability, so no `Db` token is threaded.

-- restricted monad; IO at base, no MonadIO exported
newtype ReducerM a
ask        :: ReducerM ReducerContext
throwError :: Text -> ReducerM a

-- table-op primitives (typed per-table accessors are Phase 3)
tableId :: Text -> ReducerM TableId
insert  :: TableId -> ByteString -> ReducerM ()   -- row pre-encoded to BSATN
scan    :: TableId -> ReducerM [ByteString]        -- each row raw BSATN
delete  :: TableId -> ByteString -> ReducerM ()    -- delete-by-encoded-row (thin wrapper)
```

`prim :: IO a -> ReducerM a` is defined but **not exported**; the primitives
above are implemented with it inside the library.

### The exports (library logic; example wires the glue)

Implemented once in `SpacetimeDB.Server.Runtime`:

```haskell
runDescribe    :: ModuleDef -> Word32 -> IO ()
runCallReducer :: ModuleDef
               -> Word32                      -- reducer id
               -> Word64 -> Word64 -> Word64 -> Word64   -- sender (Identity, 32 bytes LE)
               -> Word64 -> Word64             -- connection id (16 bytes LE; all-zero = None)
               -> Word64                       -- timestamp (micros)
               -> Word32 -> Word32             -- args source, error sink
               -> IO Int16
```

The example module provides the ~4 lines of `foreign export ccall` glue that
forward `hs_describe`/`hs_call_reducer` to these, plus its `ModuleDef`.

**C-shim change from Phase 0:** `__call_reducer__` must forward **all** its
parameters to `hs_call_reducer` (Phase 0 discarded sender/conn/timestamp). The
shim signature is unchanged on the host side; only the Haskell-facing wrapper
gains the extra params.

### Dispatch semantics (`runCallReducer`)

1. Reinterpret the 4 sender words → 32-byte `Identity`; the 2 conn words →
   16-byte value, `Nothing` if all-zero; the ts word → `Timestamp` (micros).
2. Stream the args source (`bytes_source_read` loop: harvest bytes every call,
   stop iff `rc == -1`).
3. Index `reducers` by id; out-of-range → write a message to the error sink,
   return `HOST_CALL_FAILURE`.
4. Run the entry's `argDecoder` with `runExact` on the args bytes; decode
   failure → error sink + `HOST_CALL_FAILURE`.
5. Run the handler in `ReducerM`; `Left msg` (from `throwError`) → error sink +
   `HOST_CALL_FAILURE`; `Right ()` → `0`.

`runDescribe` streams `schemaBytes` to the sink via a multi-chunk write loop
honoring the returned length.

### Build pipeline

Generalize Phase 0's scripts to drive cabal:
1. `wasm32-wasi-cabal build exe:person-module-example` (reactor flags +
   `--export`s + C-shim in `c-sources`).
2. Locate the reactor `.wasm` under `dist-newstyle`.
3. `wizer-init.sh` → `stub-wasi.sh` → `check-imports.sh` — carried over from
   Phase 0 unchanged (they operate on the located wasm). `wasi_stubs.c` and the
   stub-merge step are reused verbatim.

## Error handling

- Host errno / `i16` semantics as in Phase 0 (`0` ok; `-1` = source exhausted;
  `HOST_CALL_FAILURE = 1` for reducer failures).
- Reducer failure paths (unknown id, decode failure, `throwError`) all write a
  human-readable message to the error `BytesSink` and return `HOST_CALL_FAILURE`
  — never trap.
- A Haskell exception escaping a handler is caught by the runtime, logged via
  `console_log` at panic level, and converted to `HOST_CALL_FAILURE` (defensive;
  handlers should use `throwError`).

## Testing strategy

- **Hermetic (reuse Phase 0's Track-B Rust host):** extend `add_spacetime_stubs`
  with the extra `spacetime_10.0` funcs the runtime uses (table scan, `row_iter`
  advance/close, delete). Tests:
  - the example module builds and both reducers **dispatch by id**;
  - the `ReducerContext` is populated — a test drives non-zero sender/timestamp
    and a reducer asserts it observed them (e.g. inserts a row derived from
    `ctx.timestamp`);
  - a **decode failure** and a **`throwError`** each return `HOST_CALL_FAILURE`
    with error-sink bytes and **no trap**;
  - the **multi-chunk `readSource`** path is covered (a reducer arg > 4096 bytes)
    — the hardening the Phase 0 final review requested, folded in here.
- **Live (reuse `live-check.sh`):** publish the example to a real `spacetime`
  server; call both reducers and confirm rows via `SELECT`; call the failing
  reducer and confirm the error surfaces (not a trap).
- **Golden schema:** hand-captured from a Rust fixture with the *same
  two-reducer shape* (extend `fixture-person`), keeping the example's provided
  `schemaBytes` a real, reproducible oracle until Phase 2 generates them.
- **Regression:** the existing client library's 82 hermetic tests must still
  pass after the `bsatn` extraction (a behavior-preserving refactor).

## Definition of done

A hand-written example module using the library — one table plus **at least two
reducers** (e.g. `add(name: string)` and a second reducer taking a different arg
type, to exercise id-dispatch and typed decoding):

1. builds via `wasm32-wasi-cabal`, Wizer + stubs to **zero WASI imports**
   (machine-checked);
2. runs in the reused Track-B host with dispatch-by-id and a populated
   `ReducerContext`; decode-failure and `throwError` surface as
   `HOST_CALL_FAILURE` (no trap); the multi-chunk args path passes;
3. publishes to a real `spacetime` server where **both reducers round-trip**
   (rows observable via `SELECT`) and a reducer failure surfaces as an error;
4. the client library's 82 hermetic tests still pass after the `bsatn`
   extraction.

Schema bytes remain hand-captured (as in Phase 0); type-derived schema is Phase 2.

## Named risks & mitigations

| # | Risk | Mitigation |
|---|------|------------|
| 1 | `wasm32-wasi-cabal` can't cross-compile a dep (e.g. `wide-word`) | Verify early with a spike building `bsatn` alone to wasm before the runtime; if a dep is genuinely unbuildable, vendor the needed types (fallback noted, not expected) |
| 2 | Reactor + exports don't come through cabal ghc-options cleanly | Mirror Phase 0's working flags; the example is an `executable` with `-no-hs-main -optl-mexec-model=reactor` + `--export`s |
| 3 | `bsatn` extraction breaks the client build/tests | Behavior-preserving move; run the full 82-test client suite as a gate |
| 4 | GC/fuel/epoch interaction under many reducer calls | Reentrancy test (many calls); deeper fuel analysis remains a later concern |
| 5 | Existential `Reducer` + `runExact` typing friction | Standard existential pattern; the smart ctor `reducer` closes over the decoder |
