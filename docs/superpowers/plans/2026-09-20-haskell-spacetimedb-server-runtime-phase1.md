# Haskell SpacetimeDB Server Runtime — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable `spacetime-server` Haskell library that turns an author-provided `ModuleDef` (schema bytes + typed reducer list) into a working, WASI-free SpacetimeDB module, cross-compiled via `wasm32-wasi-cabal`.

**Architecture:** A `Backend` record abstracts the host effects so the runtime's pure core (context decoding, reducer-id dispatch, the restricted `ReducerM`) is unit-testable under native GHC with a fake backend, while a wasm-gated ABI module binds the real `spacetime_10.0` FFI. The BSATN codec is extracted into a shared pure `bsatn` library so the wasm build avoids the client's networking deps. The example reactor module is built by cabal, then Wizer-snapshotted and WASI-stripped by the (reused) Phase-0 pipeline.

**Tech Stack:** GHC 9.12 wasm backend via `wasm32-wasi-cabal` (`ghc-wasm-meta`), `wizer`, `binaryen` `wasm-merge`, `wasm-tools`, Rust + `wasmtime` (Phase-0 Track-B host), the `spacetime` CLI, hspec (native tests).

**Design reference:** `docs/superpowers/specs/2026-09-20-haskell-spacetimedb-server-runtime-phase1-design.md`.
**Predecessor artifacts (present on this branch):** `phase0/module/cbits/{spacetime_abi.c,spacetime_abi.h,wasi_stubs.c}`, `phase0/scripts/{wizer-init,stub-wasi,check-imports,live-check}.sh`, `phase0/host/` (Track-B Rust host).

**Conventions:** run all toolchain commands via `nix develop .#wasm --command bash -c '...'`; for native cabal use `nix develop .#dev --command bash -c '...'`; for cargo, `rustup default stable` first. End every commit body with:
```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016WZ3cT8fjfvnPjMTPJFi54
```

## File structure created/modified

```
hs-spacetime.cabal                  -- MODIFY: add `bsatn` + `spacetime-server` libs, `wasm` flag, example exe
bsatn/src/SpacetimeDB/BSATN/{Decoder,Encoder,Types}.hs   -- MOVED from src/ (git mv)
server/src/SpacetimeDB/Server.hs             -- public API re-exports
server/src/SpacetimeDB/Server/Internal.hs    -- ReducerM ctor, Backend, unReducerM (not re-exported raw)
server/src/SpacetimeDB/Server/Types.hs       -- ModuleDef, Reducer, ReducerContext, TableId, ReducerM API
server/src/SpacetimeDB/Server/Dispatch.hs    -- mkContext, dispatchReducer, describeBytes (pure, native-testable)
server/src/SpacetimeDB/Server/ABI.hs         -- wasm-gated: FFI, ffiBackend, runDescribe, runCallReducer
server/cbits/spacetime_abi.{c,h}             -- adapted from phase0 (forward all params + scan/delete shims)
server/cbits/wasi_stubs.c                    -- copied from phase0
server/example/PersonModule.hs               -- the example reactor (ModuleDef + foreign-export glue)
server/fixture-event/                        -- Rust golden oracle (event table, 3 reducers)
phase1/scripts/{build-module,wizer-init,stub-wasi,live-check}.sh   -- cabal-driven pipeline
phase1/golden/event.schema.bsatn             -- captured golden schema
test/SpacetimeDB/Server/{TypesSpec,DispatchSpec}.hs   -- native hspec unit tests
```

---

## Task 1: Extract BSATN into a shared `bsatn` internal library

**Files:** Modify `hs-spacetime.cabal`; `git mv` the three BSATN modules to `bsatn/src/`.

- [ ] **Step 1: Move the BSATN sources**

```bash
cd /home/ben/dev/hs-spacetime/.worktrees/phase1-server-runtime
mkdir -p bsatn/src/SpacetimeDB/BSATN
git mv src/SpacetimeDB/BSATN/Decoder.hs bsatn/src/SpacetimeDB/BSATN/Decoder.hs
git mv src/SpacetimeDB/BSATN/Encoder.hs bsatn/src/SpacetimeDB/BSATN/Encoder.hs
git mv src/SpacetimeDB/BSATN/Types.hs   bsatn/src/SpacetimeDB/BSATN/Types.hs
```

- [ ] **Step 2: Add the `bsatn` library and wire the main library to it**

In `hs-spacetime.cabal`, add this component immediately after the `common warnings` block:

```
library bsatn
  import:           warnings
  hs-source-dirs:   bsatn/src
  default-language: Haskell2010
  exposed-modules:  SpacetimeDB.BSATN.Decoder
                    SpacetimeDB.BSATN.Encoder
                    SpacetimeDB.BSATN.Types
  build-depends:    base >=4.14 && <5, bytestring, text, wide-word
```

In the existing `library` stanza: (a) remove the three `SpacetimeDB.BSATN.*` lines from `exposed-modules`; (b) add a `reexported-modules` field so external consumers' imports keep working; (c) add `bsatn` to `build-depends`:

```
  reexported-modules: SpacetimeDB.BSATN.Decoder
                    , SpacetimeDB.BSATN.Encoder
                    , SpacetimeDB.BSATN.Types
  build-depends:    base >=4.14 && <5
                  , bsatn
                  , bytestring
                  ... (rest unchanged)
```

- [ ] **Step 3: Build and run the full native suite (behavior-preserving gate)**

Run: `nix develop .#dev --command bash -c 'cabal build all && cabal test --test-show-details=direct 2>&1 | tail -8'`
Expected: `82 examples, 0 failures` and `Test suite hs-spacetime-test: PASS`. The reexports mean the test suite's `import SpacetimeDB.BSATN.*` and the client modules resolve unchanged.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(phase1): extract BSATN into shared pure `bsatn` library"
```

---

## Task 2: Prove `wasm32-wasi-cabal` cross-compiles `bsatn` (risk gate)

This de-risks the whole phase: if `wide-word` (and the closure) won't cross-compile, we learn now.

**Files:** Create `phase1/scripts/wasm-build.sh` (partial; extended in Task 8).

- [ ] **Step 1: Write a minimal wasm-cabal probe script**

`phase1/scripts/wasm-build.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
# Cross-compile just the pure bsatn library (+ its wide-word dep) to wasm.
wasm32-wasi-cabal build bsatn
echo "BSATN_WASM_OK"
```

- [ ] **Step 2: Run it**

Run: `nix develop .#wasm --command bash -c 'chmod +x phase1/scripts/wasm-build.sh && phase1/scripts/wasm-build.sh 2>&1 | tail -20'`
Expected: dependency builds (including `wide-word`) then `BSATN_WASM_OK`. If `wasm32-wasi-cabal` cannot resolve/build a dependency, capture the exact error and STOP — this is the risk the spec flagged (risk #1); report it before proceeding. A likely first-run need: `wasm32-wasi-cabal update` to populate the package index; run it if the build complains about no index.

- [ ] **Step 3: Commit**

```bash
git add phase1/scripts/wasm-build.sh && git commit -m "build(phase1): wasm32-wasi-cabal probe — bsatn cross-compiles"
```

---

## Task 3: Server runtime types + restricted `ReducerM` (pure, native)

**Files:** Create `server/src/SpacetimeDB/Server/Internal.hs`, `server/src/SpacetimeDB/Server/Types.hs`; add the `spacetime-server` library + `wasm` flag to `hs-spacetime.cabal`.

- [ ] **Step 1: Add the `wasm` flag and the `spacetime-server` library to the cabal file**

Add near the top (after `build-type`):
```
flag wasm
  description: Build the wasm-only server ABI module and example reactor.
  default:     False
  manual:      True
```
Add this library component:
```
library spacetime-server
  import:           warnings
  hs-source-dirs:   server/src
  default-language: Haskell2010
  exposed-modules:  SpacetimeDB.Server
                    SpacetimeDB.Server.Types
                    SpacetimeDB.Server.Dispatch
  other-modules:    SpacetimeDB.Server.Internal
  build-depends:    base >=4.14 && <5, bytestring, text, bsatn
  if flag(wasm)
    exposed-modules: SpacetimeDB.Server.ABI
    c-sources:       server/cbits/spacetime_abi.c
    include-dirs:    server/cbits
    install-includes: spacetime_abi.h
```
(The pure modules build natively; the FFI `ABI` module + C shim compile only under `-fwasm`.)

- [ ] **Step 2: Write `server/src/SpacetimeDB/Server/Internal.hs`**

```haskell
{-# LANGUAGE ExistentialQuantification #-}
module SpacetimeDB.Server.Internal where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word32)
import SpacetimeDB.BSATN.Decoder (Decoder)
import SpacetimeDB.BSATN.Types (ConnectionId, Identity, Timestamp)

newtype TableId = TableId Word32 deriving (Eq, Show)

-- | Decoded reducer invocation context (pure data).
data ReducerContext = ReducerContext
  { sender       :: Identity
  , connectionId :: Maybe ConnectionId
  , timestamp    :: Timestamp
  }

-- | The host-effect capability set. Native tests inject a fake; the wasm ABI
-- module injects one backed by FFI. Each op reports failure as 'Left' errno text.
data Backend = Backend
  { beTableId :: Text -> IO (Either Text TableId)
  , beInsert  :: TableId -> ByteString -> IO (Either Text ())
  , beScan    :: TableId -> IO (Either Text [ByteString])
  , beDelete  :: TableId -> ByteString -> IO (Either Text ())
  , beLog     :: Text -> IO ()
  }

-- | Restricted reducer monad: IO at the base, but no MonadIO is exported, so a
-- reducer can only perform effects through the primitives below.
newtype ReducerM a = ReducerM { unReducerM :: ReducerContext -> Backend -> IO (Either Text a) }

instance Functor ReducerM where
  fmap f (ReducerM g) = ReducerM $ \c b -> fmap (fmap f) (g c b)

instance Applicative ReducerM where
  pure x = ReducerM $ \_ _ -> pure (Right x)
  ReducerM gf <*> ReducerM gx = ReducerM $ \c b -> do
    ef <- gf c b
    case ef of
      Left e  -> pure (Left e)
      Right f -> fmap (fmap f) (gx c b)

instance Monad ReducerM where
  ReducerM g >>= k = ReducerM $ \c b -> do
    ex <- g c b
    case ex of
      Left e  -> pure (Left e)
      Right x -> unReducerM (k x) c b

-- | Internal bridge from a backend op into ReducerM. NOT re-exported publicly.
backendOp :: (Backend -> IO (Either Text a)) -> ReducerM a
backendOp f = ReducerM $ \_ b -> f b

data Reducer = forall a. Reducer (Decoder a) (a -> ReducerM ())

data ModuleDef = ModuleDef
  { schemaBytes :: ByteString
  , reducers    :: [Reducer]
  }
```

- [ ] **Step 3: Write `server/src/SpacetimeDB/Server/Types.hs` (the safe public surface)**

```haskell
module SpacetimeDB.Server.Types
  ( ModuleDef (..)
  , Reducer
  , reducer
  , ReducerContext (..)
  , ReducerM
  , TableId
  , ask
  , throwError
  , tableId
  , insert
  , scan
  , delete
  , logLine
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import SpacetimeDB.BSATN.Decoder (Decoder)
import SpacetimeDB.Server.Internal

-- | Build a reducer from an argument decoder and a handler.
reducer :: Decoder a -> (a -> ReducerM ()) -> Reducer
reducer = Reducer

ask :: ReducerM ReducerContext
ask = ReducerM $ \c _ -> pure (Right c)

throwError :: Text -> ReducerM a
throwError e = ReducerM $ \_ _ -> pure (Left e)

tableId :: Text -> ReducerM TableId
tableId n = backendOp (`beTableId` n)

insert :: TableId -> ByteString -> ReducerM ()
insert t row = backendOp (\b -> beInsert b t row)

scan :: TableId -> ReducerM [ByteString]
scan t = backendOp (`beScan` t)

delete :: TableId -> ByteString -> ReducerM ()
delete t row = backendOp (\b -> beDelete b t row)

logLine :: Text -> ReducerM ()
logLine msg = backendOp (\b -> Right <$> beLog b msg)
```
(Note: `ReducerM` is exported as a type only — no constructor — so users cannot fabricate `IO`. `reducer`/`ask`/`throwError`/table-ops are the entire vocabulary.)

- [ ] **Step 4: Build natively to type-check**

Run: `nix develop .#dev --command bash -c 'cabal build spacetime-server 2>&1 | tail -15'`
Expected: compiles cleanly (the pure modules build without the `wasm` flag).

- [ ] **Step 5: Commit**

```bash
git add hs-spacetime.cabal server/src/SpacetimeDB/Server/Internal.hs server/src/SpacetimeDB/Server/Types.hs
git commit -m "feat(phase1): server runtime types + restricted ReducerM (pure core)"
```

---

## Task 4: Dispatch core + context decoding (pure, native, TDD)

**Files:** Create `server/src/SpacetimeDB/Server/Dispatch.hs`, `server/src/SpacetimeDB/Server.hs`; create native test `test/SpacetimeDB/Server/DispatchSpec.hs`; register it in the test-suite.

- [ ] **Step 1: Write `server/src/SpacetimeDB/Server/Dispatch.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module SpacetimeDB.Server.Dispatch
  ( mkContext
  , dispatchReducer
  , describeBytes
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Types (Timestamp (..), connectionIdFromInteger, identityFromInteger)
import SpacetimeDB.Server.Internal

-- | Assemble a ReducerContext from the raw ABI words.
mkContext :: Word64 -> Word64 -> Word64 -> Word64   -- sender (Identity, 4 LE words)
          -> Word64 -> Word64                        -- connection id (2 LE words)
          -> Word64                                  -- timestamp micros
          -> ReducerContext
mkContext s0 s1 s2 s3 c0 c1 ts = ReducerContext
  { sender       = identityFromInteger (le4 s0 s1 s2 s3)
  , connectionId = if c0 == 0 && c1 == 0
                     then Nothing
                     else Just (connectionIdFromInteger (le2 c0 c1))
  , timestamp    = Timestamp (fromIntegral ts)
  }
  where
    le2 a b = toInteger a .|. (toInteger b `shiftL` 64)
    le4 a b c d = toInteger a .|. (toInteger b `shiftL` 64)
                            .|. (toInteger c `shiftL` 128) .|. (toInteger d `shiftL` 192)

-- | Look up a reducer by ABI id, decode its args, run its handler.
dispatchReducer :: ModuleDef -> Int -> ReducerContext -> ByteString -> Backend -> IO (Either Text ())
dispatchReducer md rid ctx args be =
  case drop rid (reducers md) of
    []                    -> pure (Left ("unknown reducer id " <> T.pack (show rid)))
    (Reducer dec h : _)   -> case runExact dec args of
      Left err -> pure (Left ("arg decode failed: " <> T.pack (show err)))
      Right a  -> unReducerM (h a) ctx be

describeBytes :: ModuleDef -> ByteString
describeBytes = schemaBytes
```

- [ ] **Step 2: Write `server/src/SpacetimeDB/Server.hs` (umbrella re-export)**

```haskell
module SpacetimeDB.Server
  ( module SpacetimeDB.Server.Types
  , mkContext
  , dispatchReducer
  , describeBytes
  ) where

import SpacetimeDB.Server.Dispatch (describeBytes, dispatchReducer, mkContext)
import SpacetimeDB.Server.Types
```

- [ ] **Step 3: Write the failing native test `test/SpacetimeDB/Server/DispatchSpec.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module SpacetimeDB.Server.DispatchSpec (spec) where

import Data.IORef
import qualified Data.ByteString as BS
import Test.Hspec
import SpacetimeDB.BSATN.Decoder (string, u32)
import SpacetimeDB.BSATN.Encoder (encodeString, runEncoder)
import SpacetimeDB.BSATN.Types (ConnectionId, Timestamp (..), connectionIdFromInteger)
import SpacetimeDB.Server
import SpacetimeDB.Server.Internal (Backend (..), TableId (..))

-- A fake backend that records inserts into an IORef.
fakeBackend :: IORef [(TableId, BS.ByteString)] -> Backend
fakeBackend ref = Backend
  { beTableId = \_ -> pure (Right (TableId 1))
  , beInsert  = \t row -> modifyIORef' ref (++ [(t, row)]) >> pure (Right ())
  , beScan    = \_ -> pure (Right [])
  , beDelete  = \_ _ -> pure (Right ())
  , beLog     = \_ -> pure ()
  }

-- Module with two reducers of different arg types.
testModule :: ModuleDef
testModule = ModuleDef "SCHEMA"
  [ reducer string $ \name -> do
      t <- tableId "person"
      insert t (runEncoder encodeString name)
  , reducer u32 $ \n ->
      if n == 0 then throwError "must be positive"
                else pure ()
  ]

ctx0 :: ReducerContext
ctx0 = mkContext 0 0 0 0 0 0 0

spec :: Spec
spec = describe "dispatch" $ do
  it "dispatches reducer 0 (string) and inserts" $ do
    ref <- newIORef []
    let args = runEncoder encodeString "alice"
    r <- dispatchReducer testModule 0 ctx0 args (fakeBackend ref)
    r `shouldBe` Right ()
    rows <- readIORef ref
    rows `shouldBe` [(TableId 1, args)]

  it "dispatches reducer 1 (u32) and throwError surfaces as Left" $ do
    ref <- newIORef []
    r <- dispatchReducer testModule 1 ctx0 (BS.pack [0,0,0,0]) (fakeBackend ref)
    r `shouldBe` Left "must be positive"

  it "unknown reducer id is Left, not a crash" $ do
    ref <- newIORef []
    r <- dispatchReducer testModule 9 ctx0 BS.empty (fakeBackend ref)
    r `shouldBe` Left "unknown reducer id 9"

  it "arg decode failure is Left" $ do
    ref <- newIORef []
    r <- dispatchReducer testModule 0 ctx0 (BS.pack [1,2]) (fakeBackend ref)  -- truncated string
    case r of Left m -> take' m `shouldBe` "arg decode failed:"; _ -> expectationFailure "expected Left"

  it "mkContext maps a zero connection id to Nothing and non-zero to Just" $ do
    connectionId (mkContext 0 0 0 0 0 0 5) `shouldBe` (Nothing :: Maybe ConnectionId)
    connectionId (mkContext 0 0 0 0 7 0 5) `shouldBe` Just (connectionIdFromInteger 7)
    timestamp (mkContext 0 0 0 0 0 0 42) `shouldBe` Timestamp 42
  where
    take' = Prelude.take 18 . show
```

- [ ] **Step 4: Register the test module + dep in the test-suite**

In the `test-suite hs-spacetime-test` stanza of `hs-spacetime.cabal`: add `SpacetimeDB.Server.DispatchSpec` to `other-modules`, and add `spacetime-server` to its `build-depends`. Then add its `spec` to the hspec runner: open `test/Spec.hs` and register `SpacetimeDB.Server.DispatchSpec.spec` following the existing pattern used for the other specs (they are wired explicitly — mirror the nearest `describe`/`specify` registration).

- [ ] **Step 5: Run the test — expect FAIL then PASS**

Run: `nix develop .#dev --command bash -c 'cabal test 2>&1 | tail -15'`
Expected: after implementing Steps 1-2 the 5 dispatch examples PASS and the prior 82 still pass (`87 examples, 0 failures`).

- [ ] **Step 6: Commit**

```bash
git add hs-spacetime.cabal server/src/SpacetimeDB/Server.hs server/src/SpacetimeDB/Server/Dispatch.hs test/SpacetimeDB/Server/DispatchSpec.hs test/Spec.hs
git commit -m "feat(phase1): reducer dispatch + context decoding, native unit tests"
```

---

## Task 5: The C shim + WASI stubs for the server library

**Files:** Create `server/cbits/spacetime_abi.h`, `server/cbits/spacetime_abi.c`, `server/cbits/wasi_stubs.c` (adapted from Phase 0).

- [ ] **Step 1: Copy the Phase-0 cbits as the starting point**

```bash
mkdir -p server/cbits
cp phase0/module/cbits/spacetime_abi.h server/cbits/spacetime_abi.h
cp phase0/module/cbits/spacetime_abi.c server/cbits/spacetime_abi.c
cp phase0/module/cbits/wasi_stubs.c    server/cbits/wasi_stubs.c
```

- [ ] **Step 2: Extend the header with the scan/delete host imports**

Append to `server/cbits/spacetime_abi.h` (before the final content ends), matching the SpacetimeDB v2.10 ABI:
```c
// datastore_table_scan_bsatn(table_id, out_iter) -> u16 errno
ST_IMPORT("datastore_table_scan_bsatn")
uint16_t st_datastore_table_scan_bsatn(uint32_t table_id, uint32_t *out_iter);
// row_iter_bsatn_advance(iter, buf, buf_len) -> i16 (0 ok/more, -1 exhausted, >0 errno)
ST_IMPORT("row_iter_bsatn_advance")
int16_t st_row_iter_bsatn_advance(uint32_t iter, uint8_t *buf, size_t *buf_len);
// row_iter_bsatn_close(iter) -> u16 errno
ST_IMPORT("row_iter_bsatn_close")
uint16_t st_row_iter_bsatn_close(uint32_t iter);
// datastore_delete_all_by_eq_bsatn(table_id, rel, rel_len, out_count) -> u16 errno
ST_IMPORT("datastore_delete_all_by_eq_bsatn")
uint16_t st_datastore_delete_all_by_eq_bsatn(uint32_t table_id, const uint8_t *rel, size_t rel_len, uint32_t *out_count);
```

- [ ] **Step 3: Rewrite `spacetime_abi.c` to forward ALL reducer params and add the new shims**

Replace the body of `server/cbits/spacetime_abi.c` with:
```c
#include "spacetime_abi.h"
#include "HsFFI.h"

// Haskell entry points (foreign export ccall in the example module).
extern void  hs_describe(uint32_t sink);
extern int16_t hs_call_reducer(uint32_t id,
        uint64_t s0, uint64_t s1, uint64_t s2, uint64_t s3,
        uint64_t c0, uint64_t c1, uint64_t timestamp,
        uint32_t args, uint32_t error);

__attribute__((constructor))
static void phase1_init_rts(void) {
    int argc = 0;
    char *argv_storage[] = { 0 };
    char **argv = argv_storage;
    hs_init(&argc, &argv);
}

__attribute__((export_name("__describe_module__")))
void __describe_module__(uint32_t description) { hs_describe(description); }

// Forward EVERY parameter to Haskell (Phase 0 dropped sender/conn/timestamp).
__attribute__((export_name("__call_reducer__")))
int16_t __call_reducer__(uint32_t id,
        uint64_t s0, uint64_t s1, uint64_t s2, uint64_t s3,
        uint64_t c0, uint64_t c1, uint64_t timestamp,
        uint32_t args, uint32_t error) {
    return hs_call_reducer(id, s0, s1, s2, s3, c0, c1, timestamp, args, error);
}

// FFI wrappers so Haskell (which emits imports into "env") reaches the real
// spacetime_10.0 imports. Thin pass-throughs.
uint16_t shim_table_id_from_name(const uint8_t *n, size_t nl, uint32_t *o) { return st_table_id_from_name(n, nl, o); }
uint16_t shim_datastore_insert_bsatn(uint32_t t, uint8_t *r, size_t *rl) { return st_datastore_insert_bsatn(t, r, rl); }
int16_t  shim_bytes_source_read(uint32_t s, uint8_t *b, size_t *bl) { return st_bytes_source_read(s, b, bl); }
uint16_t shim_bytes_sink_write(uint32_t s, const uint8_t *b, size_t *bl) { return st_bytes_sink_write(s, b, bl); }
void     shim_console_log(uint8_t lvl, const uint8_t *t, size_t tl, const uint8_t *f, size_t fl, uint32_t line, const uint8_t *m, size_t ml) { st_console_log(lvl, t, tl, f, fl, line, m, ml); }
uint16_t shim_datastore_table_scan_bsatn(uint32_t t, uint32_t *o) { return st_datastore_table_scan_bsatn(t, o); }
int16_t  shim_row_iter_bsatn_advance(uint32_t it, uint8_t *b, size_t *bl) { return st_row_iter_bsatn_advance(it, b, bl); }
uint16_t shim_row_iter_bsatn_close(uint32_t it) { return st_row_iter_bsatn_close(it); }
uint16_t shim_datastore_delete_all_by_eq_bsatn(uint32_t t, const uint8_t *r, size_t rl, uint32_t *o) { return st_datastore_delete_all_by_eq_bsatn(t, r, rl, o); }
```
(If the Phase-0 `spacetime_abi.h` did not declare `st_console_log`/`st_bytes_source_read`/`st_bytes_sink_write`, keep those declarations from Phase 0 — they already exist there; only the four scan/delete decls in Step 2 are new.)

- [ ] **Step 4: Commit** (compilation is verified in Task 7's build)

```bash
git add server/cbits
git commit -m "feat(phase1): server C shim (forward all reducer params) + scan/delete + WASI stubs"
```

---

## Task 6: The wasm-gated ABI module (FFI backend + entry points)

**Files:** Create `server/src/SpacetimeDB/Server/ABI.hs` (compiled only under `-fwasm`).

- [ ] **Step 1: Write `server/src/SpacetimeDB/Server/ABI.hs`**

```haskell
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module SpacetimeDB.Server.ABI
  ( ffiBackend
  , runDescribe
  , runCallReducer
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Int (Int16)
import Data.Word (Word8, Word16, Word32, Word64)
import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek, poke)
import Data.Text (Text)
import SpacetimeDB.Server.Dispatch (describeBytes, dispatchReducer, mkContext)
import SpacetimeDB.Server.Internal

foreign import ccall unsafe "shim_table_id_from_name"
  c_table_id_from_name :: Ptr Word8 -> CSize -> Ptr Word32 -> IO Word16
foreign import ccall unsafe "shim_datastore_insert_bsatn"
  c_insert :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16
foreign import ccall unsafe "shim_bytes_source_read"
  c_source_read :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Int16
foreign import ccall unsafe "shim_bytes_sink_write"
  c_sink_write :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16
foreign import ccall unsafe "shim_console_log"
  c_console_log :: Word8 -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Word32 -> Ptr Word8 -> CSize -> IO ()
foreign import ccall unsafe "shim_datastore_table_scan_bsatn"
  c_scan :: Word32 -> Ptr Word32 -> IO Word16
foreign import ccall unsafe "shim_row_iter_bsatn_advance"
  c_iter_advance :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Int16
foreign import ccall unsafe "shim_row_iter_bsatn_close"
  c_iter_close :: Word32 -> IO Word16
foreign import ccall unsafe "shim_datastore_delete_all_by_eq_bsatn"
  c_delete_eq :: Word32 -> Ptr Word8 -> CSize -> Ptr Word32 -> IO Word16

errnoText :: Word16 -> Text
errnoText e = "spacetime errno " <> T.pack (show e)

okOr :: Word16 -> a -> Either Text a
okOr 0 a = Right a
okOr e _ = Left (errnoText e)

-- Read one host stream (source) fully: harvest bytes on EVERY read, stop on -1.
readSource :: Word32 -> IO BS.ByteString
readSource src = go BS.empty
  where
    cap = 4096
    go acc = allocaBytes cap $ \buf -> alloca $ \lenp -> do
      poke lenp (fromIntegral cap)
      rc <- c_source_read src buf lenp
      n  <- peek lenp
      chunk <- BS.packCStringLen (castPtr buf, fromIntegral n)
      let acc' = acc <> chunk
      if rc == (-1) then pure acc' else go acc'

writeSink :: Word32 -> BS.ByteString -> IO ()
writeSink sink payload =
  BSU.unsafeUseAsCStringLen payload $ \(ptr, len) -> alloca $ \lenp -> do
    poke lenp (fromIntegral len)
    _ <- c_sink_write sink (castPtr ptr) lenp
    pure ()

-- A row iterator drained the same way as a source.
drainIter :: Word32 -> IO [BS.ByteString]
drainIter it = go []
  where
    cap = 4096
    go acc = allocaBytes cap $ \buf -> alloca $ \lenp -> do
      poke lenp (fromIntegral cap)
      rc <- c_iter_advance it buf lenp
      n  <- peek lenp
      row <- BS.packCStringLen (castPtr buf, fromIntegral n)
      let acc' = if n > 0 then acc ++ [row] else acc
      if rc == (-1) then c_iter_close it >> pure acc' else go acc'

ffiBackend :: Backend
ffiBackend = Backend
  { beTableId = \name ->
      BSU.unsafeUseAsCStringLen (TE.encodeUtf8 name) $ \(p, l) -> alloca $ \o -> do
        e <- c_table_id_from_name (castPtr p) (fromIntegral l) o
        v <- peek o
        pure (okOr e (TableId v))
  , beInsert = \(TableId t) row ->
      BSU.unsafeUseAsCStringLen row $ \(p, l) -> alloca $ \lenp -> do
        poke lenp (fromIntegral l)
        e <- c_insert t (castPtr p) lenp
        pure (okOr e ())
  , beScan = \(TableId t) -> alloca $ \o -> do
      e <- c_scan t o
      if e /= 0 then pure (Left (errnoText e)) else Right <$> (peek o >>= drainIter)
  , beDelete = \(TableId t) row ->
      BSU.unsafeUseAsCStringLen row $ \(p, l) -> alloca $ \o -> do
        e <- c_delete_eq t (castPtr p) (fromIntegral l) o
        pure (okOr e ())
  , beLog = \msg ->
      BSU.unsafeUseAsCStringLen (TE.encodeUtf8 msg) $ \(p, l) ->
        c_console_log 3 (castPtr p) 0 (castPtr p) 0 0 (castPtr p) (fromIntegral l)
  }

runDescribe :: ModuleDef -> Word32 -> IO ()
runDescribe md sink = writeSink sink (describeBytes md)

runCallReducer :: ModuleDef
               -> Word32 -> Word64 -> Word64 -> Word64 -> Word64
               -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> IO Int16
runCallReducer md rid s0 s1 s2 s3 c0 c1 ts argsSrc errSink = do
  let ctx = mkContext s0 s1 s2 s3 c0 c1 ts
  args <- readSource argsSrc
  res  <- dispatchReducer md (fromIntegral rid) ctx args ffiBackend
  case res of
    Right () -> pure 0
    Left msg -> do writeSink errSink (TE.encodeUtf8 msg); pure 1
```
Note: `beLog`'s `console_log` passes empty target/filename (len 0) and the message; level 3 = info. That matches the host's tolerance for null target/filename in Phase 0.

- [ ] **Step 2: Type-check under the wasm flag (compile only)**

Run: `nix develop .#wasm --command bash -c 'wasm32-wasi-cabal build spacetime-server -fwasm 2>&1 | tail -20'`
Expected: the library (including `ABI` + the C shim) compiles for wasm. Fix any FFI signature mismatches against the header. (No link step yet — that's the example in Task 7.)

- [ ] **Step 3: Commit**

```bash
git add server/src/SpacetimeDB/Server/ABI.hs
git commit -m "feat(phase1): wasm ABI module — FFI backend + describe/call_reducer entry points"
```

---

## Task 7: Rust `event` golden fixture + capture the schema

**Files:** Create `server/fixture-event/{Cargo.toml,src/lib.rs,.cargo/config.toml,.gitignore}`; `phase1/scripts/capture-golden.sh`; generate `phase1/golden/event.schema.bsatn`.

- [ ] **Step 1: Write the Rust fixture (table `event{who,at}`, reducers `record`, `record_n`, `delete_all`)**

`server/fixture-event/Cargo.toml`:
```toml
[package]
name = "phase1-fixture-event"
version = "0.1.0"
edition = "2021"
[lib]
crate-type = ["cdylib"]
[dependencies]
spacetimedb = "2.10"
[profile.release]
opt-level = "z"
lto = true
```
`server/fixture-event/src/lib.rs`:
```rust
use spacetimedb::{reducer, table, ReducerContext, Table};

#[table(accessor = event, public)]
pub struct Event {
    pub who: String,
    pub at: i64,
}

#[reducer]
pub fn record(ctx: &ReducerContext, note: String) {
    ctx.db.event().insert(Event { who: note, at: ctx.timestamp.to_micros_since_unix_epoch() });
}

#[reducer]
pub fn record_n(ctx: &ReducerContext, count: u32) {
    ctx.db.event().insert(Event { who: "n".into(), at: count as i64 });
}

#[reducer]
pub fn delete_all(ctx: &ReducerContext) {
    for e in ctx.db.event().iter() { ctx.db.event().delete(e); }
}
```
Copy `.cargo/config.toml` (CC=gcc) and `.gitignore` (`/target`) from `phase0/fixture-person/`:
```bash
mkdir -p server/fixture-event/.cargo
cp phase0/fixture-person/.cargo/config.toml server/fixture-event/.cargo/config.toml
cp phase0/fixture-person/.gitignore server/fixture-event/.gitignore
```
Mirror the exact `#[table]`/`#[reducer]`/timestamp API of `phase0/fixture-person` and the existing `fixture/`; if `to_micros_since_unix_epoch` differs in 2.10, use the spelling those working fixtures use.

- [ ] **Step 2: Write `phase1/scripts/capture-golden.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/server/fixture-event"
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cargo build --release --target wasm32-unknown-unknown
wasm="target/wasm32-unknown-unknown/release/phase1_fixture_event.wasm"
cd "$root/phase0/host"   # reuse the Phase-0 describe host binary
cargo run --quiet --bin phase0-host -- --describe "$root/server/fixture-event/$wasm" \
  > "$root/phase1/golden/event.schema.bsatn"
echo "wrote phase1/golden/event.schema.bsatn ($(wc -c < "$root/phase1/golden/event.schema.bsatn") bytes)"
```

- [ ] **Step 3: Capture the golden**

Run: `nix develop .#wasm --command bash -c 'mkdir -p phase1/golden && rustup default stable >/dev/null 2>&1; chmod +x phase1/scripts/capture-golden.sh && phase1/scripts/capture-golden.sh'`
Expected: `wrote phase1/golden/event.schema.bsatn (N bytes)`, N > 0. (The reused `phase0-host --describe` already runs `__preinit__` describers + `define_unknown_imports_as_traps`.)

- [ ] **Step 4: Commit**

```bash
git add server/fixture-event phase1/scripts/capture-golden.sh phase1/golden/event.schema.bsatn
git commit -m "feat(phase1): Rust event fixture (3 reducers) + captured golden schema"
```

---

## Task 8: The example module + build to a WASI reactor via cabal

**Files:** Create `server/example/PersonModule.hs`; add the `person-module-example` executable to the cabal file; write `phase1/scripts/build-module.sh`.

- [ ] **Step 1: Add the example executable to `hs-spacetime.cabal` (wasm-gated)**

```
executable person-module-example
  import:           warnings
  default-language: Haskell2010
  hs-source-dirs:   server/example
  main-is:          PersonModule.hs
  if !flag(wasm)
    buildable: False
  if flag(wasm)
    build-depends:  base, bytestring, text, bsatn, spacetime-server
    ghc-options:    -no-hs-main -optl-mexec-model=reactor
                    -optl-Wl,--export=__describe_module__
                    -optl-Wl,--export=__call_reducer__
                    -optl-Wl,--export=_initialize
                    -optl-Wl,--export-memory
```

- [ ] **Step 2: Write `server/example/PersonModule.hs`**

Generate the embedded golden bytes: `nix develop .#wasm --command bash -c 'xxd -i < phase1/golden/event.schema.bsatn'` and paste the `0xNN,` list into `eventSchema` below (verify the count matches `wc -c`).
```haskell
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module PersonModule where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.ByteString (ByteString)
import Data.Int (Int16, Int64)
import Data.Word (Word32, Word64)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import SpacetimeDB.BSATN.Decoder (string, u32)
import SpacetimeDB.BSATN.Types (Timestamp (..))
import SpacetimeDB.Server
import SpacetimeDB.Server.ABI (runCallReducer, runDescribe)

eventSchema :: ByteString
eventSchema = BS.pack [ {- PASTE xxd -i OF phase1/golden/event.schema.bsatn -} ]

-- Encode an Event{who::Text, at::Int64} row as a BSATN product (bare concat).
encodeEvent :: Text -> Int64 -> ByteString
encodeEvent who at = BL.toStrict . BB.toLazyByteString $
  BB.word32LE (fromIntegral (BS.length (TE.encodeUtf8 who)))
  <> BB.byteString (TE.encodeUtf8 who)
  <> BB.int64LE at

theModule :: ModuleDef
theModule = ModuleDef eventSchema
  [ reducer string $ \note -> do            -- reducer 0: record(note)
      ctx <- ask
      let Timestamp micros = timestamp ctx
      t <- tableId "event"
      insert t (encodeEvent note micros)
  , reducer u32 $ \count -> do              -- reducer 1: record_n(count)
      if count == 0
        then throwError "count must be positive"
        else do t <- tableId "event"; insert t (encodeEvent "n" (fromIntegral count))
  , reducer (pure ()) $ \() -> do           -- reducer 2: delete_all()
      t <- tableId "event"
      rows <- scan t
      mapM_ (delete t) rows
  ]

foreign export ccall hs_describe :: Word32 -> IO ()
hs_describe :: Word32 -> IO ()
hs_describe = runDescribe theModule

foreign export ccall hs_call_reducer
  :: Word32 -> Word64 -> Word64 -> Word64 -> Word64
  -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> IO Int16
hs_call_reducer :: Word32 -> Word64 -> Word64 -> Word64 -> Word64
                -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> IO Int16
hs_call_reducer = runCallReducer theModule
```
Note: `reducer (pure ())` uses a decoder that consumes no bytes for the no-arg `delete_all`. If `pure ()` is not a `Decoder ()` in the codec, use the codec's unit decoder; if none exists, add `unit :: Decoder ()` to `bsatn` (a `Decoder` that returns `()` consuming nothing) — a one-liner — and export it. Confirm against `SpacetimeDB.BSATN.Decoder`.

- [ ] **Step 3: Write `phase1/scripts/build-module.sh`**

```bash
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
```

- [ ] **Step 4: Build and verify the required exports**

Run:
```
nix develop .#wasm --command bash -c '
  chmod +x phase1/scripts/build-module.sh && phase1/scripts/build-module.sh
  wasm-tools print server/example/person-module.wasm | grep -E "\(export \"(__describe_module__|__call_reducer__|memory|_initialize)\""'
```
Expected: `built ...`, then the four export lines. If cabal doesn't accept an `executable` with no `main`, confirm `-no-hs-main` is in `ghc-options`; if `find` returns nothing, inspect `dist-newstyle/build/.../person-module-example*` for the actual artifact name and adjust the glob.

- [ ] **Step 5: Add `server/example/*.wasm` to `.gitignore` and commit sources**

```bash
grep -qxF 'server/example/*.wasm' .gitignore || echo 'server/example/*.wasm' >> .gitignore
git add hs-spacetime.cabal server/example/PersonModule.hs phase1/scripts/build-module.sh .gitignore
git commit -m "feat(phase1): example module builds to a WASI reactor via wasm32-wasi-cabal"
```

---

## Task 9: Wizer + WASI-strip the cabal-built module (zero WASI)

**Files:** Create `phase1/scripts/{wizer-init,stub-wasi,check-imports}.sh` (adapted from Phase 0 to the cabal output path).

- [ ] **Step 1: Create the Phase-1 pipeline scripts from the Phase-0 ones**

```bash
mkdir -p phase1/scripts
cp phase0/scripts/wizer-init.sh   phase1/scripts/wizer-init.sh
cp phase0/scripts/stub-wasi.sh    phase1/scripts/stub-wasi.sh
cp phase0/scripts/check-imports.sh phase1/scripts/check-imports.sh
```
Edit `phase1/scripts/wizer-init.sh` and `phase1/scripts/stub-wasi.sh`: change the input/output paths from `phase0/module/person-module*.wasm` to `server/example/person-module*.wasm`, and point the stub compile at `server/cbits/wasi_stubs.c` (instead of `phase0/module/cbits/wasi_stubs.c`). Keep the pipeline logic (wizer `--allow-wasi --init-func _initialize --wasm-bulk-memory true`; `wasm-merge` with the `env`-named primary + `wasi_snapshot_preview1`-named stub) identical. `check-imports.sh` already takes a wasm path argument — no edit needed beyond a default of `server/example/person-module.nowasi.wasm`.

- [ ] **Step 2: Run the pipeline and assert zero WASI imports**

Run:
```
nix develop .#wasm --command bash -c '
  chmod +x phase1/scripts/*.sh
  phase1/scripts/build-module.sh
  phase1/scripts/wizer-init.sh
  phase1/scripts/stub-wasi.sh
  phase1/scripts/check-imports.sh server/example/person-module.nowasi.wasm
  wasm-tools validate server/example/person-module.nowasi.wasm && echo VALIDATE_OK'
```
Expected: `OK: ... zero wasi_snapshot_preview1 imports` and `VALIDATE_OK`. If new imports survive (e.g. the RTS pulled a WASI func not in `wasi_stubs.c`), add the missing stub to `server/cbits/wasi_stubs.c` (mirror the existing stubs' signatures) and re-run.

- [ ] **Step 3: Commit**

```bash
git add phase1/scripts/wizer-init.sh phase1/scripts/stub-wasi.sh phase1/scripts/check-imports.sh
git commit -m "feat(phase1): Wizer + WASI-strip pipeline for the cabal-built module"
```

---

## Task 10: Hermetic run in the Track-B host (dispatch + context + errors)

**Files:** Modify `phase0/host/src/lib.rs` (add scan/iter/delete stubs); create `phase0/host/tests/phase1_tests.rs`.

- [ ] **Step 1: Extend the Track-B host with the scan/iter/delete stubs**

In `phase0/host/src/lib.rs`, inside `add_spacetime_stubs`, register these additional `spacetime_10.0` functions (backed by the existing `inserted` map so scanned rows are the inserted ones; use a simple per-store iterator table). Add to `HostState`: `pub iters: std::collections::HashMap<u32, Vec<Vec<u8>>>` and `pub next_iter: u32` (init `1`). Then:
```rust
// datastore_table_scan_bsatn(table_id, out_iter_ptr) -> u16
self.linker.func_wrap("spacetime_10.0", "datastore_table_scan_bsatn", |mut caller: Caller<'_, HostState>,
    table_id: i32, out: i32| -> i32 {
    let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
    let rows = caller.data().inserted.get(&(table_id as u32)).cloned().unwrap_or_default();
    let id = { let s = caller.data_mut(); let i = s.next_iter; s.next_iter += 1; s.iters.insert(i, rows); i };
    mem.write(&mut caller, out as usize, &id.to_le_bytes()).unwrap();
    0
})?;
// row_iter_bsatn_advance(iter, buf, buf_len_ptr) -> i16 : one row per call; -1 with last
self.linker.func_wrap("spacetime_10.0", "row_iter_bsatn_advance", |mut caller: Caller<'_, HostState>,
    iter: i32, buf: i32, buf_len_ptr: i32| -> i32 {
    let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
    let mut remaining = caller.data().iters.get(&(iter as u32)).cloned().unwrap_or_default();
    if remaining.is_empty() { let mut z=[0u8;4]; mem.write(&mut caller, buf_len_ptr as usize, &z).unwrap(); let _=&mut z; return -1; }
    let row = remaining.remove(0);
    let mut cap = [0u8;4]; mem.read(&caller, buf_len_ptr as usize, &mut cap).unwrap();
    mem.write(&mut caller, buf as usize, &row).unwrap();
    mem.write(&mut caller, buf_len_ptr as usize, &(row.len() as u32).to_le_bytes()).unwrap();
    let done = remaining.is_empty();
    caller.data_mut().iters.insert(iter as u32, remaining);
    if done { -1 } else { 0 }
})?;
// row_iter_bsatn_close(iter) -> u16
self.linker.func_wrap("spacetime_10.0", "row_iter_bsatn_close", |mut caller: Caller<'_, HostState>, iter: i32| -> i32 {
    caller.data_mut().iters.remove(&(iter as u32)); 0
})?;
// datastore_delete_all_by_eq_bsatn(table_id, rel_ptr, rel_len, out_count) -> u16
self.linker.func_wrap("spacetime_10.0", "datastore_delete_all_by_eq_bsatn", |mut caller: Caller<'_, HostState>,
    table_id: i32, rel: i32, rel_len: i32, out: i32| -> i32 {
    let mem = caller.get_export("memory").unwrap().into_memory().unwrap();
    let mut needle = vec![0u8; rel_len as usize]; mem.read(&caller, rel as usize, &mut needle).unwrap();
    let before; let after;
    { let rows = caller.data_mut().inserted.entry(table_id as u32).or_default();
      before = rows.len(); rows.retain(|r| r != &needle); after = rows.len(); }
    mem.write(&mut caller, out as usize, &((before - after) as u32).to_le_bytes()).unwrap();
    0
})?;
```
(Adjust to the exact `HostState`/`Caller` idioms already in the file. Also add the two new fields to `HostState::new()`.)

- [ ] **Step 2: Write the hermetic test `phase0/host/tests/phase1_tests.rs`**

```rust
use phase0_host::Host;

fn bsatn_string(s: &str) -> Vec<u8> {
    let mut v = (s.len() as u32).to_le_bytes().to_vec(); v.extend_from_slice(s.as_bytes()); v
}
fn event_row(who: &str, at: i64) -> Vec<u8> {
    let mut v = bsatn_string(who); v.extend_from_slice(&at.to_le_bytes()); v
}
const NOWASI: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../server/example/person-module.nowasi.wasm");

fn fresh() -> (Host, wasmtime::Instance) {
    let wasm = std::fs::read(NOWASI).expect("run phase1 build+wizer+stub first");
    let mut host = Host::new(false).unwrap();      // WASI OFF
    host.add_spacetime_stubs().unwrap();
    host.store.data_mut().table_ids.insert("event".into(), 1);
    let inst = host.instantiate(&wasm).unwrap();
    host.initialize(&inst).unwrap();
    (host, inst)
}

#[test]
fn record_uses_context_timestamp() {
    let (mut host, inst) = fresh();
    // call_reducer id=0 with a non-zero timestamp; assert the inserted row carries it.
    // Extend the host driver to pass a timestamp; here we use call_reducer_full if available,
    // else the existing call_reducer with ts wired through.
    let (errno, err) = host.call_reducer_ts(&inst, 0, 12345, bsatn_string("hi")).unwrap();
    assert_eq!(errno, 0, "{}", String::from_utf8_lossy(&err));
    assert_eq!(host.store.data().inserted.get(&1).unwrap(), &vec![event_row("hi", 12345)]);
}

#[test]
fn record_n_zero_is_error_not_trap() {
    let (mut host, inst) = fresh();
    let (errno, err) = host.call_reducer_ts(&inst, 1, 0, vec![0,0,0,0]).unwrap(); // u32 count = 0
    assert_eq!(errno, 1);
    assert!(String::from_utf8_lossy(&err).contains("positive"));
}

#[test]
fn delete_all_scans_and_deletes() {
    let (mut host, inst) = fresh();
    host.call_reducer_ts(&inst, 0, 1, bsatn_string("a")).unwrap();
    host.call_reducer_ts(&inst, 0, 2, bsatn_string("b")).unwrap();
    assert_eq!(host.store.data().inserted.get(&1).unwrap().len(), 2);
    let (errno, _) = host.call_reducer_ts(&inst, 2, 0, vec![]).unwrap(); // delete_all, no args
    assert_eq!(errno, 0);
    assert_eq!(host.store.data().inserted.get(&1).map(|v| v.len()).unwrap_or(0), 0);
}

#[test]
fn multi_chunk_args_over_4096() {
    let (mut host, inst) = fresh();
    let big = "x".repeat(5000);
    let (errno, err) = host.call_reducer_ts(&inst, 0, 7, bsatn_string(&big)).unwrap();
    assert_eq!(errno, 0, "{}", String::from_utf8_lossy(&err));
    assert_eq!(host.store.data().inserted.get(&1).unwrap(), &vec![event_row(&big, 7)]);
}
```

- [ ] **Step 3: Add a `call_reducer_ts` driver that threads sender/timestamp**

In `phase0/host/src/lib.rs`, add a variant of `call_reducer` that sets a non-zero timestamp (and zero sender/conn) so the context test is meaningful:
```rust
pub fn call_reducer_ts(&mut self, instance: &Instance, id: u32, ts: u64, args: Vec<u8>) -> Result<(i32, Vec<u8>)> {
    let args_source: u32 = 2; let error_sink: u32 = 3;
    self.store.data_mut().sources.insert(args_source, args);
    self.store.data_mut().sinks.insert(error_sink, Vec::new());
    let f = instance.get_typed_func::<(i32,i64,i64,i64,i64,i64,i64,i64,i32,i32), i32>(&mut self.store, "__call_reducer__")?;
    let errno = f.call(&mut self.store, (id as i32, 0,0,0,0, 0,0, ts as i64, args_source as i32, error_sink as i32))?;
    let err = self.store.data().sinks.get(&error_sink).cloned().unwrap_or_default();
    Ok((errno, err))
}
```

- [ ] **Step 4: Build the module + run the hermetic tests**

Run:
```
nix develop .#wasm --command bash -c '
  phase1/scripts/build-module.sh && phase1/scripts/wizer-init.sh && phase1/scripts/stub-wasi.sh
  cd phase0/host && rustup default stable >/dev/null 2>&1; cargo test --test phase1_tests -- --nocapture'
```
Expected: 4 passed. (Existing `host_tests` remain green.)

- [ ] **Step 5: Commit**

```bash
git add phase0/host/src/lib.rs phase0/host/tests/phase1_tests.rs
git commit -m "test(phase1): hermetic host — dispatch, context, error, scan/delete, multi-chunk args"
```

---

## Task 11: Live publish + reducer round-trip (M-A)

**Files:** Create `phase1/scripts/live-check.sh` (adapted from Phase 0); create `phase1/GO-NO-GO.md`.

- [ ] **Step 1: Adapt the live-check script**

```bash
cp phase0/scripts/live-check.sh phase1/scripts/live-check.sh
```
Edit `phase1/scripts/live-check.sh`: publish `server/example/person-module.nowasi.wasm` (not the phase0 path) as db `event-hs`; replace the single-reducer call with the three:
```bash
# after publish:
spacetime call --server "$URL" event-hs record '"carol"'
spacetime call --server "$URL" event-hs record_n '3'
spacetime sql --server "$URL" event-hs 'SELECT COUNT(*) AS n FROM event'      # expect 2
spacetime call --server "$URL" event-hs record_n '0' || echo "record_n(0) correctly rejected"
spacetime call --server "$URL" event-hs delete_all
spacetime sql --server "$URL" event-hs 'SELECT COUNT(*) AS n FROM event'      # expect 0
```
Keep the throwaway-server / random-port / `trap teardown` / `--anonymous --yes` scaffolding and the reducer-name→id mapping (SpacetimeDB maps by name; our positional list order `record, record_n, delete_all` must match the golden schema's reducer order — the Rust fixture defines them in that order, so it does).

- [ ] **Step 2: Run the live check**

Run:
```
nix develop .#wasm --command bash -c '
  phase1/scripts/build-module.sh && phase1/scripts/wizer-init.sh && phase1/scripts/stub-wasi.sh
  chmod +x phase1/scripts/live-check.sh && phase1/scripts/live-check.sh'
```
Expected: publish accepted; `record`/`record_n(3)` succeed; count = 2; `record_n(0)` rejected (error, not trap); `delete_all` succeeds; final count = 0. No traps in `spacetime logs`.

- [ ] **Step 3: Record the verdict**

Create `phase1/GO-NO-GO.md` summarizing: the runtime library builds via `wasm32-wasi-cabal` (deps incl. `wide-word` cross-compiled), the example publishes and all three reducers round-trip (typed dispatch by id, `ReducerContext` timestamp observed via `record`, `throwError` surfaced via `record_n(0)`, scan+delete via `delete_all`), zero WASI imports, and the native `bsatn`/dispatch unit tests pass. Note any deviations.

- [ ] **Step 4: Final full regression + commit**

Run: `nix develop .#dev --command bash -c 'cabal test 2>&1 | tail -5'`
Expected: `87 examples, 0 failures` (82 client + 5 dispatch).
```bash
git add phase1/scripts/live-check.sh phase1/GO-NO-GO.md
git commit -m "test(phase1): M-A — live publish, 3 reducers round-trip; record verdict"
```

---

## Self-Review

**Spec coverage:**
- `wasm32-wasi-cabal` cracked → Task 2 (bsatn probe) + Task 8 (full build). ✓
- BSATN extraction into shared pure lib → Task 1 (+ client 82-test gate). ✓
- Generalized C-shim (forward all params + scan/delete) → Task 5. ✓
- Two exports in the library / example glue → Tasks 6, 8. ✓
- Typed multi-reducer id-dispatch → Task 4 (dispatch) + Task 10 (live/hermetic). ✓
- Restricted `ReducerM` (no MonadIO, IO at base via `Backend`) → Task 3. ✓
- `ReducerContext` decode (identity/conn/timestamp) → Task 4 `mkContext` + Task 10 context test. ✓
- BytesSource/Sink streaming (`-1`-with-final-chunk) → Task 6 `readSource`/`drainIter`. ✓
- errno/error-sink + unit reducers → Task 6 `runCallReducer` + Task 10 error test. ✓
- Raw table ops (tableId/insert/scan/delete) → Tasks 3 (API), 6 (FFI), 10 (exercised). ✓
- console_log logging → Task 6 `beLog`. ✓
- Build/Wizer/stub pipeline → Tasks 8, 9. ✓
- Golden fixture (same 3-reducer shape) → Task 7. ✓
- Multi-chunk `readSource` test (Phase-0 review ask) → Task 10 `multi_chunk_args_over_4096`. ✓
- Client 82-test regression gate → Tasks 1, 11. ✓

**Placeholder scan:** The only bracketed fill-in is the golden byte list in Task 8 Step 2, with the exact `xxd -i` command to generate it and a count check — an unavoidable captured-data paste, not deferred work. Two "confirm against the codec" notes (unit decoder in Task 8; timestamp API in Task 7) name the exact fallback (add a one-line `unit`/mirror the working fixture). No TODO/TBD/"handle errors" placeholders.

**Type consistency:** `Backend` field names (`beTableId`/`beInsert`/`beScan`/`beDelete`/`beLog`) are consistent across Tasks 3, 4 (fake), 6 (ffi). `ReducerM`/`reducer`/`ask`/`throwError`/`tableId`/`insert`/`scan`/`delete`/`logLine` consistent Tasks 3→6→8. `mkContext`/`dispatchReducer`/`describeBytes` signatures match between Task 4 (def), Task 6 (call), and Task 10 (behavior). `TableId` newtype consistent. `runCallReducer` 10-arg signature matches the C shim in Task 5 and the `foreign export` in Task 8. `call_reducer_ts` (Task 10) matches the `__call_reducer__` typed signature.
