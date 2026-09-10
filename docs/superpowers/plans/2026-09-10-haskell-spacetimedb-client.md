# Haskell SpacetimeDB Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a full-featured SpacetimeDB v2 WebSocket client library for Haskell (`v2.bsatn.spacetimedb`) plus a bindings generator, bottom-up in four layers with a hermetic test suite and an opt-in live suite.

**Architecture:** Four layers, each depending only on the one below — BSATN codec → v2 protocol → client → codegen. The client uses a single durable `TVar ClientState` (pure transition functions) plus a programmatic exception-bounded reconnect loop, not an actor split. Nix `callCabal2nix` build, hspec tests, CI runs the hermetic suite only.

**Tech Stack:** GHC (Haskell2010), `bytestring`, `wide-word`, `websockets` + `wuss`, `zlib`, `brotli`, `aeson`, `text`, `containers`, `stm`, `async`, `hspec`, `QuickCheck`. Nix flake with `clockworklabs/SpacetimeDB` input for the live suite.

**Spec:** `docs/superpowers/specs/2026-09-10-haskell-spacetimedb-client-design.md`

---

## How to work this plan

- Execute phases in order (1→7). Each phase ends in a green `cabal test` and a commit.
- Every code step shows the full code for the file or the exact region to change. Do not paraphrase.
- Run `nix develop .#dev --command <cmd>` for every `cabal`/`ghc`/`fourmolu` invocation, or enter the shell once (`nix develop .#dev`) and run bare commands. The plan writes bare commands for brevity.
- Commit after each task with the shown message.

## Shared type reference (defined by the tasks below; listed here so later phases stay consistent)

These names are introduced by specific tasks and reused verbatim throughout. If a later task's usage disagrees with this list, this list wins.

```haskell
-- SpacetimeDB.BSATN.Decoder  (Task 1.3, 1.4)
data DecodeError = UnexpectedEnd | InvalidBool Word8 | InvalidUtf8
                 | UnknownVariant Word8 | Custom Text
newtype Decoder a = Decoder { runDecoder :: ByteString -> Either DecodeError (a, ByteString) }
runExact   :: Decoder a -> ByteString -> Either DecodeError a
decodeRows :: Decoder a -> [ByteString] -> Either (Int, DecodeError) [a]

-- SpacetimeDB.BSATN.Encoder  (Task 1.7)
type Encoder a = a -> Builder
runEncoder :: Encoder a -> a -> ByteString

-- SpacetimeDB.BSATN.Types  (Task 1.9)
newtype Identity      = Identity Word256      -- 32 LE
newtype ConnectionId  = ConnectionId Word128  -- 16 LE
newtype Timestamp     = Timestamp Int64       -- micros
newtype TimeDuration  = TimeDuration Int64    -- micros
newtype Uuid          = Uuid Word128          -- transparent

-- SpacetimeDB.Protocol.RowList  (Task 2.1)
data RowSizeHint = FixedSize Word16 | RowOffsets [Word64]
splitRows :: RowSizeHint -> ByteString -> [ByteString]

-- SpacetimeDB.Protocol.Messages  (Tasks 2.3–2.6)
data Compression = CompNone | CompBrotli | CompGzip
data ServerMessage = InitialConnection Identity ConnectionId Text
                   | SubscribeApplied Word32 Word32 QueryRows
                   | UnsubscribeApplied Word32 Word32 (Maybe QueryRows)
                   | SubscriptionError (Maybe Word32) Word32 Text
                   | TransactionUpdate [QuerySetUpdate]
                   | OneOffQueryResult Word32 (Either Text QueryRows)
                   | ReducerResult Word32 Timestamp ReducerOutcome
                   | ProcedureResult ProcedureStatus Timestamp TimeDuration Word32
                   | Unhandled Word8
data QueryRows       = QueryRows [SingleTableRows]
data SingleTableRows = SingleTableRows Text [ByteString]        -- table, split rows
data QuerySetUpdate  = QuerySetUpdate Word32 [TableUpdate]
data TableUpdate     = TableUpdate Text [TableUpdateRows]
data TableUpdateRows = PersistentTable [ByteString] [ByteString] -- inserts, deletes (split)
                     | EventTable [ByteString]
data ReducerOutcome  = OutcomeOk ByteString [QuerySetUpdate]     -- ret_value bytes, embedded update
                     | OutcomeOkEmpty
                     | OutcomeErr ByteString
                     | OutcomeInternalError Text
data ProcedureStatus = ProcReturned ByteString | ProcInternalError Text

-- SpacetimeDB.Protocol.Frame  (Task 2.7)
data FrameError = EmptyFrame | UnsupportedCompression Word8
                | BrotliFailed | GzipFailed | Bsatn DecodeError
decodeFrame :: ByteString -> Either FrameError ServerMessage

-- SpacetimeDB.Client.Types  (Task 4.1)
data Event = Connected Identity ConnectionId Text
           | Disconnected Text | Reconnecting Int Int
           | InitialRows Text [ByteString] | Changed Text [ByteString] [ByteString]
           | SubscriptionFailed Word32 Text | Unsubscribed Word32
           | UnhandledMessage Word8 | UnmatchedReply Word32
data ClientError = HandshakeFailed Text | DecodeFailed Text | SendFailed Text
                 | RowDecodeFailed Text RowBatch Int DecodeError | CallFailed Text Text
data RowBatch = BatchInitial | BatchInsert | BatchDelete
data ReducerReply a e = Returned a | ReturnedNothing | Failed e | ReducerCallFailed Text
data ProcedureReply a = ProcReturnedVal a | ProcedureCallFailed Text
data QueryReply       = QueryReturned [(Text, [ByteString])] | QueryRejected Text | QueryCallFailed Text
```

---

# Phase 1 — BSATN codec

Produces `SpacetimeDB.BSATN.{Decoder,Encoder,Types}` with a green round-trip property suite. No server, no socket.

### Task 1.1: Scaffold the cabal package and flake dev shell

**Files:**
- Create: `hs-spacetime.cabal`
- Create: `cabal.project`
- Create: `flake.nix`
- Create: `.envrc`
- Create: `src/SpacetimeDB.hs` (temporary stub)
- Create: `test/Spec.hs` (temporary stub)

- [ ] **Step 1: Write `cabal.project`**

```
packages: .

-- Force the solver to include the test suite in the build plan (needed for a
-- fresh `cabal test` in the Nix dev shell, which has no Hackage index).
tests: True
```

- [ ] **Step 2: Write `hs-spacetime.cabal`** (executables/other-modules grow in later tasks; this is the starting stanza set)

```
cabal-version:      3.0
name:               hs-spacetime
version:            0.1.0.0
synopsis:           Native Haskell client SDK for SpacetimeDB (v2 protocol)
license:            MIT
build-type:         Simple

common warnings
  ghc-options: -Wall

library
  import:           warnings
  hs-source-dirs:   src
  default-language: Haskell2010
  exposed-modules:  SpacetimeDB
  build-depends:    base >=4.14 && <5
                  , bytestring
                  , text
                  , containers
                  , wide-word
                  , stm
                  , async
                  , websockets
                  , wuss
                  , network
                  , zlib
                  , brotli
                  , aeson
                  , scientific
                  , vector
                  , unordered-containers

test-suite hs-spacetime-test
  import:           warnings
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Spec.hs
  default-language: Haskell2010
  other-modules:
  build-depends:    base, hs-spacetime, hspec, QuickCheck
                  , bytestring, text, containers, wide-word
```

- [ ] **Step 3: Write `flake.nix`** (two shells; `spacetime` attr resolved in Phase 6 Task 6.1 — for now the `live` shell references a placeholder we finalize then)

```nix
{
  description = "hs-spacetime — native Haskell client SDK for SpacetimeDB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    spacetimedb = {
      url = "github:clockworklabs/SpacetimeDB";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, spacetimedb }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        hs-spacetime = pkgs.haskellPackages.callCabal2nix "hs-spacetime" ./. {};
        # Hermetic shell: GHC with every dep of the package plus cabal, a
        # formatter, and the C libs the wire layer links (brotli, zlib).
        dev = hs-spacetime.env.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [])
            ++ [ pkgs.cabal-install pkgs.fourmolu pkgs.brotli pkgs.zlib pkgs.pkg-config ];
        });
        # Live shell: everything in dev, plus the spacetime CLI + a Rust wasm
        # toolchain for building the fixture module. Kept out of `dev` so CI
        # carries no compiler. spacetimeCli is finalized in Task 6.1.
        spacetimeCli = spacetimedb.packages.${system}.default;
        live = dev.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [])
            ++ [ spacetimeCli pkgs.rustup ];
        });
      in {
        packages.default = hs-spacetime;
        devShells.dev = dev;
        devShells.default = dev;
        devShells.live = live;
      });
}
```

- [ ] **Step 4: Write `.envrc`**

```
use flake
```

- [ ] **Step 5: Write stub `src/SpacetimeDB.hs`**

```haskell
module SpacetimeDB () where
```

- [ ] **Step 6: Write stub `test/Spec.hs`**

```haskell
module Main (main) where

import Test.Hspec (hspec, describe, it, shouldBe)

main :: IO ()
main = hspec $ describe "bootstrap" $ it "runs" $ (1 :: Int) `shouldBe` 1
```

- [ ] **Step 7: Build and test**

Run: `nix develop .#dev --command cabal test --test-show-details=direct`
Expected: builds, 1 example passes. (First run compiles dependencies — may take several minutes.)

- [ ] **Step 8: Commit**

```bash
git add hs-spacetime.cabal cabal.project flake.nix flake.lock .envrc src test
git commit -m "chore: scaffold hs-spacetime package and nix dev shell"
```

### Task 1.2: Decoder core type and `UnexpectedEnd`-safe byte readers

**Files:**
- Create: `src/SpacetimeDB/BSATN/Decoder.hs`
- Test: `test/SpacetimeDB/BSATN/DecoderSpec.hs`
- Modify: `hs-spacetime.cabal` (add `SpacetimeDB.BSATN.Decoder` to `exposed-modules`; add `SpacetimeDB.BSATN.DecoderSpec` to test `other-modules`)
- Modify: `test/Spec.hs`

- [ ] **Step 1: Write the failing test** — `test/SpacetimeDB/BSATN/DecoderSpec.hs`

```haskell
module SpacetimeDB.BSATN.DecoderSpec (spec) where

import qualified Data.ByteString as BS
import Test.Hspec
import SpacetimeDB.BSATN.Decoder

spec :: Spec
spec = do
  describe "takeBytes" $ do
    it "splits off n bytes and keeps the rest" $
      runDecoder (takeBytes 2) (BS.pack [1,2,3]) `shouldBe` Right (BS.pack [1,2], BS.pack [3])
    it "fails with UnexpectedEnd when short" $
      runDecoder (takeBytes 4) (BS.pack [1,2]) `shouldBe` Left UnexpectedEnd
  describe "word8" $
    it "reads one byte" $
      runDecoder word8 (BS.pack [7,8]) `shouldBe` Right (7, BS.pack [8])
```

- [ ] **Step 2: Write `src/SpacetimeDB/BSATN/Decoder.hs`** (grows in later tasks)

```haskell
{-# LANGUAGE ScopedTypeVariables #-}

module SpacetimeDB.BSATN.Decoder
  ( DecodeError (..)
  , Decoder (..)
  , takeBytes
  , word8
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Text (Text)
import Data.Word (Word8)

data DecodeError
  = UnexpectedEnd
  | InvalidBool Word8
  | InvalidUtf8
  | UnknownVariant Word8
  | Custom Text
  deriving (Eq, Show)

newtype Decoder a = Decoder { runDecoder :: ByteString -> Either DecodeError (a, ByteString) }

-- | Consume exactly @n@ bytes or fail.
takeBytes :: Int -> Decoder ByteString
takeBytes n = Decoder $ \bs ->
  if BS.length bs < n
    then Left UnexpectedEnd
    else Right (BS.splitAt n bs)

word8 :: Decoder Word8
word8 = Decoder $ \bs -> case BS.uncons bs of
  Nothing -> Left UnexpectedEnd
  Just (b, rest) -> Right (b, rest)
```

- [ ] **Step 3: Wire the test into `test/Spec.hs`**

```haskell
module Main (main) where

import Test.Hspec (hspec, describe)
import qualified SpacetimeDB.BSATN.DecoderSpec

main :: IO ()
main = hspec $ do
  describe "SpacetimeDB.BSATN.Decoder" SpacetimeDB.BSATN.DecoderSpec.spec
```

- [ ] **Step 4: Update `hs-spacetime.cabal`** — add `SpacetimeDB.BSATN.Decoder` under library `exposed-modules`, and `SpacetimeDB.BSATN.DecoderSpec` under the test suite's `other-modules`.

- [ ] **Step 5: Run**

Run: `nix develop .#dev --command cabal test --test-show-details=direct`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src test hs-spacetime.cabal
git commit -m "feat(bsatn): decoder core, takeBytes, word8"
```

### Task 1.3: Combinators — Functor/Applicative/Monad, `success`, `sumD`

**Files:**
- Modify: `src/SpacetimeDB/BSATN/Decoder.hs`
- Test: `test/SpacetimeDB/BSATN/DecoderSpec.hs`

- [ ] **Step 1: Add failing tests** (append to `DecoderSpec`)

```haskell
  describe "combinators" $ do
    it "success consumes nothing" $
      runDecoder (success 'x') (BS.pack [1]) `shouldBe` Right ('x', BS.pack [1])
    it "fmap transforms the value" $
      runDecoder (fmap (+1) word8) (BS.pack [5]) `shouldBe` Right (6, BS.empty)
    it "monadic bind threads the remainder" $ do
      let d = do a <- word8; b <- word8; pure (a, b)
      runDecoder d (BS.pack [1,2,3]) `shouldBe` Right ((1,2), BS.pack [3])
    it "sumD dispatches on the tag" $ do
      let d = sumD $ \t -> case t of
                0 -> Right (success "zero")
                1 -> Right (fmap show word8)
                _ -> Left (UnknownVariant t)
      runDecoder d (BS.pack [1,9]) `shouldBe` Right ("9", BS.empty)
    it "sumD reports unknown variants" $ do
      let d = sumD $ \t -> if t == 0 then Right (success ()) else Left (UnknownVariant t)
      runDecoder d (BS.pack [3]) `shouldBe` Left (UnknownVariant 3)
```

- [ ] **Step 2: Extend `Decoder.hs`** — add instances and combinators; update the export list to add `success` and `sumD`.

```haskell
-- add to the export list: success, sumD

instance Functor Decoder where
  fmap f (Decoder d) = Decoder $ \bs -> case d bs of
    Left e -> Left e
    Right (a, rest) -> Right (f a, rest)

instance Applicative Decoder where
  pure x = Decoder $ \bs -> Right (x, bs)
  (Decoder df) <*> (Decoder da) = Decoder $ \bs -> case df bs of
    Left e -> Left e
    Right (f, rest) -> case da rest of
      Left e -> Left e
      Right (a, rest') -> Right (f a, rest')

instance Monad Decoder where
  (Decoder d) >>= f = Decoder $ \bs -> case d bs of
    Left e -> Left e
    Right (a, rest) -> runDecoder (f a) rest

-- | Yield a value, consuming nothing. Alias for 'pure' for parity with the skill.
success :: a -> Decoder a
success = pure

-- | Read a u8 tag, then run the payload decoder that @pick@ returns.
sumD :: (Word8 -> Either DecodeError (Decoder a)) -> Decoder a
sumD pick = do
  tag <- word8
  case pick tag of
    Left e -> Decoder (const (Left e))
    Right d -> d
```

- [ ] **Step 3: Run**

Run: `nix develop .#dev --command cabal test --test-show-details=direct`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src test
git commit -m "feat(bsatn): decoder Functor/Applicative/Monad, success, sumD"
```

### Task 1.4: Integer decoders (all widths, little-endian) + `runExact`

**Files:**
- Modify: `src/SpacetimeDB/BSATN/Decoder.hs`
- Test: `test/SpacetimeDB/BSATN/DecoderSpec.hs`

- [ ] **Step 1: Add failing tests**

```haskell
  describe "integers (LE) and runExact" $ do
    it "u16 reads little-endian" $
      runExact u16 (BS.pack [0x34,0x12]) `shouldBe` Right (0x1234 :: Word16)
    it "u32 reads little-endian" $
      runExact u32 (BS.pack [1,0,0,0]) `shouldBe` Right (1 :: Word32)
    it "i8 -1 is all-ones" $
      runExact i8 (BS.pack [0xFF]) `shouldBe` Right (-1 :: Int8)
    it "u64 max" $
      runExact u64 (BS.pack [0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF]) `shouldBe` Right (maxBound :: Word64)
    it "u128 round value" $
      runExact u128 (BS.pack (1 : replicate 15 0)) `shouldBe` Right (1 :: Word128)
    it "runExact rejects trailing bytes" $
      runExact u16 (BS.pack [1,0,9]) `shouldBe` Left (Custom "trailing bytes")
```

- [ ] **Step 2: Extend `Decoder.hs`** — add imports and decoders; extend exports with `u8,i8,u16,i16,u32,i32,u64,i64,u128,i128,u256,i256,f32,f64,bool,runExact`.

```haskell
-- imports to add:
import Data.Bits (shiftL, (.|.))
import Data.Int (Int8, Int16, Int32, Int64)
import Data.Word (Word16, Word32, Word64)
import Data.WideWord (Word128, Word256, Int128, Int256)
import Data.List (foldl')
import GHC.Float (castWord32ToFloat, castWord64ToDouble)

-- | Assemble an unsigned little-endian integer of @n@ bytes into an Integer,
-- then narrow with fromInteger at the call site.
leUnsigned :: Int -> Decoder Integer
leUnsigned n = do
  bs <- takeBytes n
  pure $ foldr (\b acc -> acc `shiftL` 8 .|. fromIntegral b) 0 (BS.unpack bs)

u8  :: Decoder Word8;    u8  = word8
u16 :: Decoder Word16;   u16 = fromInteger <$> leUnsigned 2
u32 :: Decoder Word32;   u32 = fromInteger <$> leUnsigned 4
u64 :: Decoder Word64;   u64 = fromInteger <$> leUnsigned 8
u128 :: Decoder Word128; u128 = fromInteger <$> leUnsigned 16
u256 :: Decoder Word256; u256 = fromInteger <$> leUnsigned 32

i8  :: Decoder Int8;   i8  = fromIntegral <$> word8
i16 :: Decoder Int16;  i16 = fromIntegral <$> u16
i32 :: Decoder Int32;  i32 = fromIntegral <$> u32
i64 :: Decoder Int64;  i64 = fromIntegral <$> u64
i128 :: Decoder Int128; i128 = fromIntegral <$> u128
i256 :: Decoder Int256; i256 = fromIntegral <$> u256

f32 :: Decoder Float
f32 = castWord32ToFloat <$> u32

f64 :: Decoder Double
f64 = castWord64ToDouble <$> u64

bool :: Decoder Bool
bool = do
  b <- word8
  case b of
    0 -> pure False
    1 -> pure True
    _ -> Decoder (const (Left (InvalidBool b)))

-- | Run a decoder and require every byte consumed.
runExact :: Decoder a -> ByteString -> Either DecodeError a
runExact d bs = case runDecoder d bs of
  Left e -> Left e
  Right (a, rest)
    | BS.null rest -> Right a
    | otherwise    -> Left (Custom "trailing bytes")
```

Note: `u8` is the wire-name decoder (a synonym for `word8`) so codegen can derive the name `u8` from the wire type `"U8"`. Add `u8,i8,u16,i16,u32,i32,u64,i64,u128,i128,u256,i256,f32,f64,bool,runExact` to the export list.

- [ ] **Step 3: Run**

Run: `nix develop .#dev --command cabal test --test-show-details=direct`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src test
git commit -m "feat(bsatn): LE integer/float/bool decoders and runExact"
```

### Task 1.5: String, bytes, list, optional decoders + `decodeRows`

**Files:**
- Modify: `src/SpacetimeDB/BSATN/Decoder.hs`
- Test: `test/SpacetimeDB/BSATN/DecoderSpec.hs`

- [ ] **Step 1: Add failing tests**

```haskell
  describe "string/bytes/list/optional/decodeRows" $ do
    it "string is u32-length + utf8" $
      runExact string (BS.pack [3,0,0,0, 0x61,0x62,0x63]) `shouldBe` Right ("abc" :: T.Text)
    it "rejects invalid utf8" $
      runExact string (BS.pack [1,0,0,0, 0xFF]) `shouldBe` Left InvalidUtf8
    it "bytes is u32-length + raw" $
      runExact bytes (BS.pack [2,0,0,0, 9,9]) `shouldBe` Right (BS.pack [9,9])
    it "list is u32-count + elems" $
      runExact (list u8) (BS.pack [2,0,0,0, 5,6]) `shouldBe` Right [5,6]
    it "optional some=0" $
      runExact (optional u8) (BS.pack [0, 7]) `shouldBe` Right (Just 7)
    it "optional none=1" $
      runExact (optional u8) (BS.pack [1]) `shouldBe` Right Nothing
    it "decodeRows reports the failing index" $
      decodeRows u16 [BS.pack [1,0], BS.pack [2]] `shouldBe` Left (1, UnexpectedEnd)
    it "decodeRows returns all rows" $
      decodeRows u16 [BS.pack [1,0], BS.pack [2,0]] `shouldBe` Right [1,2]
```

Add `import qualified Data.Text as T` to the test.

- [ ] **Step 2: Extend `Decoder.hs`** — add exports `string, bytes, list, optional, decodeRows`.

```haskell
-- imports to add:
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text (Text)

bytes :: Decoder ByteString
bytes = do
  n <- u32
  takeBytes (fromIntegral n)

string :: Decoder Text
string = do
  raw <- bytes
  case TE.decodeUtf8' raw of
    Left _  -> Decoder (const (Left InvalidUtf8))
    Right t -> pure t

list :: Decoder a -> Decoder [a]
list elemD = do
  n <- u32
  go (fromIntegral n) []
  where
    go 0 acc = pure (reverse acc)
    go k acc = do x <- elemD; go (k - 1 :: Int) (x : acc)

-- | Option: tag 0 = some, tag 1 = none.
optional :: Decoder a -> Decoder (Maybe a)
optional someD = sumD $ \t -> case t of
  0 -> Right (Just <$> someD)
  1 -> Right (pure Nothing)
  _ -> Left (UnknownVariant t)

-- | runExact each row of a split row list, reporting the index that failed.
decodeRows :: Decoder a -> [ByteString] -> Either (Int, DecodeError) [a]
decodeRows d = go 0 []
  where
    go _ acc [] = Right (reverse acc)
    go i acc (r : rs) = case runExact d r of
      Left e  -> Left (i, e)
      Right a -> go (i + 1) (a : acc) rs
```

- [ ] **Step 3: Run**

Run: `nix develop .#dev --command cabal test --test-show-details=direct`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src test
git commit -m "feat(bsatn): string/bytes/list/optional decoders and decodeRows"
```

### Task 1.6: `result` decoder and error-path coverage

**Files:**
- Modify: `src/SpacetimeDB/BSATN/Decoder.hs`
- Test: `test/SpacetimeDB/BSATN/DecoderSpec.hs`

- [ ] **Step 1: Add failing tests**

```haskell
  describe "result" $ do
    it "ok=0" $ runExact (result u8 string) (BS.pack [0, 5]) `shouldBe` Right (Right 5)
    it "err=1" $
      runExact (result u8 string) (BS.pack [1, 1,0,0,0, 0x61]) `shouldBe` Right (Left ("a" :: T.Text))
```

- [ ] **Step 2: Add `result`** (export it)

```haskell
-- | Result: tag 0 = ok, tag 1 = err.
result :: Decoder e -> Decoder a -> Decoder (Either e a)
result errD okD = sumD $ \t -> case t of
  0 -> Right (Right <$> okD)
  1 -> Right (Left <$> errD)
  _ -> Left (UnknownVariant t)
```

- [ ] **Step 3: Run / Step 4: Commit**

Run: `nix develop .#dev --command cabal test --test-show-details=direct` → PASS.

```bash
git add src test && git commit -m "feat(bsatn): result decoder"
```

### Task 1.7: Encoder combinators (primitives, concat, contramap, sum, list, optional)

**Files:**
- Create: `src/SpacetimeDB/BSATN/Encoder.hs`
- Test: `test/SpacetimeDB/BSATN/EncoderSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write failing test** — `test/SpacetimeDB/BSATN/EncoderSpec.hs`

```haskell
module SpacetimeDB.BSATN.EncoderSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.BSATN.Encoder

spec :: Spec
spec = do
  it "encodeU32 is little-endian" $
    runEncoder encodeU32 1 `shouldBe` BS.pack [1,0,0,0]
  it "encodeString is u32-len + utf8" $
    runEncoder encodeString (T.pack "abc") `shouldBe` BS.pack [3,0,0,0,0x61,0x62,0x63]
  it "encodeBool" $ runEncoder encodeBool True `shouldBe` BS.pack [1]
  it "concatE lays fields end to end" $
    runEncoder (\(_ :: ()) -> concatE [encodeU8 1, encodeU16 2]) () `shouldBe` BS.pack [1, 2,0]
  it "encodeOptional some=0" $
    runEncoder (\x -> encodeOptional x encodeU8) (Just 7) `shouldBe` BS.pack [0,7]
  it "encodeOptional none=1" $
    runEncoder (\x -> encodeOptional x encodeU8) Nothing `shouldBe` BS.pack [1]
  it "encodeList is u32-count + elems" $
    runEncoder (\xs -> encodeList xs encodeU8) [5,6] `shouldBe` BS.pack [2,0,0,0,5,6]
  it "encodeSum writes tag then payload" $
    runEncoder (\() -> encodeSum 2 (encodeU8 9)) () `shouldBe` BS.pack [2,9]
```

- [ ] **Step 2: Write `src/SpacetimeDB/BSATN/Encoder.hs`**

```haskell
module SpacetimeDB.BSATN.Encoder
  ( Encoder
  , runEncoder
  , encodeU8, encodeU16, encodeU32, encodeU64, encodeU128, encodeU256
  , encodeI8, encodeI16, encodeI32, encodeI64, encodeI128, encodeI256
  , encodeF32, encodeF64, encodeBool
  , encodeString, encodeBytes
  , concatE, contramap, encodeSum
  , encodeList, encodeOptional, encodeResult
  , encodeListOf, encodeOptionalOf
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int8, Int16, Int32, Int64)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word8, Word16, Word32, Word64)
import Data.WideWord (Word128, Word256, Int128, Int256)
import Data.Bits (shiftR, (.&.))

type Encoder a = a -> B.Builder

runEncoder :: Encoder a -> a -> ByteString
runEncoder e = BL.toStrict . B.toLazyByteString . e

encodeU8  :: Encoder Word8;  encodeU8  = B.word8
encodeU16 :: Encoder Word16; encodeU16 = B.word16LE
encodeU32 :: Encoder Word32; encodeU32 = B.word32LE
encodeU64 :: Encoder Word64; encodeU64 = B.word64LE
encodeI8  :: Encoder Int8;   encodeI8  = B.int8
encodeI16 :: Encoder Int16;  encodeI16 = B.int16LE
encodeI32 :: Encoder Int32;  encodeI32 = B.int32LE
encodeI64 :: Encoder Int64;  encodeI64 = B.int64LE
encodeF32 :: Encoder Float;  encodeF32 = B.floatLE
encodeF64 :: Encoder Double; encodeF64 = B.doubleLE

-- Wide words: emit LE bytes by repeated shift.
leBytesOf :: Int -> Integer -> B.Builder
leBytesOf n = go n
  where
    go 0 _ = mempty
    go k v = B.word8 (fromIntegral (v .&. 0xFF)) <> go (k - 1) (v `shiftR` 8)

encodeU128 :: Encoder Word128; encodeU128 = leBytesOf 16 . toInteger
encodeU256 :: Encoder Word256; encodeU256 = leBytesOf 32 . toInteger
encodeI128 :: Encoder Int128;  encodeI128 = leBytesOf 16 . toIntegerMod (16*8)
encodeI256 :: Encoder Int256;  encodeI256 = leBytesOf 32 . toIntegerMod (32*8)

-- two's-complement wrap into an unsigned Integer of the given bit width
toIntegerMod :: Integral a => Int -> a -> Integer
toIntegerMod bits x = toInteger x `mod` (2 ^ bits)

encodeBool :: Encoder Bool
encodeBool b = B.word8 (if b then 1 else 0)

encodeBytes :: Encoder ByteString
encodeBytes bs = B.word32LE (fromIntegral (BS.length bs)) <> B.byteString bs

encodeString :: Encoder Text
encodeString = encodeBytes . TE.encodeUtf8

concatE :: [B.Builder] -> B.Builder
concatE = mconcat

contramap :: (b -> a) -> Encoder a -> Encoder b
contramap f enc = enc . f

encodeSum :: Word8 -> B.Builder -> B.Builder
encodeSum tag payload = B.word8 tag <> payload

encodeList :: [a] -> Encoder a -> B.Builder
encodeList xs enc = B.word32LE (fromIntegral (length xs)) <> mconcat (map enc xs)

encodeListOf :: Encoder a -> Encoder [a]
encodeListOf enc xs = encodeList xs enc

encodeOptional :: Maybe a -> Encoder a -> B.Builder
encodeOptional Nothing  _   = B.word8 1
encodeOptional (Just x) enc = B.word8 0 <> enc x

encodeOptionalOf :: Encoder a -> Encoder (Maybe a)
encodeOptionalOf enc mx = encodeOptional mx enc

encodeResult :: Either e a -> Encoder e -> Encoder a -> B.Builder
encodeResult (Right a) _   encA = B.word8 0 <> encA a
encodeResult (Left e)  encE _   = B.word8 1 <> encE e
```

- [ ] **Step 3: Wire into cabal + Spec.hs** — add `SpacetimeDB.BSATN.Encoder` to `exposed-modules`, `SpacetimeDB.BSATN.EncoderSpec` to test `other-modules`, and a `describe "SpacetimeDB.BSATN.Encoder" SpacetimeDB.BSATN.EncoderSpec.spec` line (with the import) to `test/Spec.hs`.

- [ ] **Step 4: Run / Step 5: Commit**

Run: `nix develop .#dev --command cabal test --test-show-details=direct` → PASS.

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(bsatn): encoder combinators"
```

### Task 1.8: Round-trip property tests with boundary-biased generators

**Files:**
- Create: `test/SpacetimeDB/BSATN/RoundtripSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write the property spec** — `test/SpacetimeDB/BSATN/RoundtripSpec.hs`

```haskell
module SpacetimeDB.BSATN.RoundtripSpec (spec) where

import Data.Int (Int64)
import Data.Word (Word64, Word128)
import Data.WideWord (Word128)
import Test.Hspec
import Test.QuickCheck
import SpacetimeDB.BSATN.Decoder
import SpacetimeDB.BSATN.Encoder

-- Build a wide value from 30-bit chunks so the high bytes are exercised
-- (QuickCheck's integral gen is 32-bit internally).
wideWord64 :: Gen Word64
wideWord64 = do
  hi <- choose (0, 2^(30::Int) - 1) :: Gen Integer
  mid <- choose (0, 2^(30::Int) - 1) :: Gen Integer
  lo <- choose (0, 2^(30::Int) - 1) :: Gen Integer
  pure (fromInteger ((hi * 2^(34::Int)) + (mid * 2^(4::Int)) + lo))

boundaries64 :: [Word64]
boundaries64 = [0, 1, 2^(63::Int), maxBound]

roundtrip :: (Eq a, Show a) => Encoder a -> Decoder a -> a -> Expectation
roundtrip enc dec x = runExact dec (runEncoder enc x) `shouldBe` Right x

spec :: Spec
spec = do
  describe "u64 round-trip" $ do
    it "hits boundaries" $ mapM_ (roundtrip encodeU64 u64) boundaries64
    it "holds for wide randoms" $ property $ forAll wideWord64 $ \w ->
      runExact u64 (runEncoder encodeU64 w) === Right w
  describe "i64 round-trip" $
    it "holds incl. -1" $ property $ \(i :: Int64) ->
      runExact i64 (runEncoder encodeI64 i) === Right i
  describe "u128 round-trip" $
    it "boundaries" $ mapM_ (roundtrip encodeU128 u128)
      [0, 1, 2^(127::Int), maxBound :: Word128]
```

- [ ] **Step 2: Wire into cabal + Spec.hs** (add module to both).

- [ ] **Step 3: Run**

Run: `nix develop .#dev --command cabal test --test-show-details=direct`
Expected: PASS (properties green).

- [ ] **Step 4: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "test(bsatn): boundary-biased round-trip properties"
```

### Task 1.9: Special/opaque types (`Identity`, `ConnectionId`, `Timestamp`, `TimeDuration`, `Uuid`)

**Files:**
- Create: `src/SpacetimeDB/BSATN/Types.hs`
- Test: `test/SpacetimeDB/BSATN/TypesSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write failing test** — `test/SpacetimeDB/BSATN/TypesSpec.hs`

```haskell
module SpacetimeDB.BSATN.TypesSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.BSATN.Types

spec :: Spec
spec = do
  it "Identity is 32 LE bytes, round-trips" $ do
    let bytes32 = BS.pack (1 : replicate 31 0)
    runExact decodeIdentity bytes32 `shouldBe` Right (identityFromInteger 1)
    runEncoder encodeIdentity (identityFromInteger 1) `shouldBe` bytes32
  it "Identity renders as 64 lowercase hex, zero-padded" $
    identityToHex (identityFromInteger 1)
      `shouldBe` T.pack ("000000000000000000000000000000000000000000000000000000000000000" ++ "1")
  it "Timestamp is i64 micros" $
    runExact decodeTimestamp (BS.pack (replicate 8 0)) `shouldBe` Right (Timestamp 0)
```

- [ ] **Step 2: Write `src/SpacetimeDB/BSATN/Types.hs`**

```haskell
module SpacetimeDB.BSATN.Types
  ( Identity, identityFromInteger, identityToInteger, identityToHex
  , decodeIdentity, encodeIdentity
  , ConnectionId, connectionIdFromInteger, connectionIdToInteger, connectionIdToHex
  , decodeConnectionId, encodeConnectionId
  , Timestamp (..), decodeTimestamp, encodeTimestamp
  , TimeDuration (..), decodeTimeDuration, encodeTimeDuration
  , Uuid (..), decodeUuid, encodeUuid
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.WideWord (Word128, Word256)
import Numeric (showHex)
import SpacetimeDB.BSATN.Decoder
import SpacetimeDB.BSATN.Encoder

newtype Identity = Identity Word256 deriving (Eq, Ord, Show)
identityFromInteger :: Integer -> Identity
identityFromInteger = Identity . fromInteger
identityToInteger :: Identity -> Integer
identityToInteger (Identity w) = toInteger w
identityToHex :: Identity -> Text
identityToHex (Identity w) = T.pack (pad 64 (showHex (toInteger w) ""))
decodeIdentity :: Decoder Identity
decodeIdentity = Identity <$> u256
encodeIdentity :: Encoder Identity
encodeIdentity (Identity w) = encodeU256 w

newtype ConnectionId = ConnectionId Word128 deriving (Eq, Ord, Show)
connectionIdFromInteger :: Integer -> ConnectionId
connectionIdFromInteger = ConnectionId . fromInteger
connectionIdToInteger :: ConnectionId -> Integer
connectionIdToInteger (ConnectionId w) = toInteger w
connectionIdToHex :: ConnectionId -> Text
connectionIdToHex (ConnectionId w) = T.pack (pad 32 (showHex (toInteger w) ""))
decodeConnectionId :: Decoder ConnectionId
decodeConnectionId = ConnectionId <$> u128
encodeConnectionId :: Encoder ConnectionId
encodeConnectionId (ConnectionId w) = encodeU128 w

newtype Timestamp = Timestamp Int64 deriving (Eq, Ord, Show)
decodeTimestamp :: Decoder Timestamp
decodeTimestamp = Timestamp <$> i64
encodeTimestamp :: Encoder Timestamp
encodeTimestamp (Timestamp v) = encodeI64 v

newtype TimeDuration = TimeDuration Int64 deriving (Eq, Ord, Show)
decodeTimeDuration :: Decoder TimeDuration
decodeTimeDuration = TimeDuration <$> i64
encodeTimeDuration :: Encoder TimeDuration
encodeTimeDuration (TimeDuration v) = encodeI64 v

newtype Uuid = Uuid Word128 deriving (Eq, Ord, Show)
decodeUuid :: Decoder Uuid
decodeUuid = Uuid <$> u128
encodeUuid :: Encoder Uuid
encodeUuid (Uuid w) = encodeU128 w

pad :: Int -> String -> String
pad n s = replicate (n - length s) '0' ++ s
```

- [ ] **Step 3: Wire into cabal + Spec.hs.**

- [ ] **Step 4: Run / Step 5: Commit**

Run: `nix develop .#dev --command cabal test --test-show-details=direct` → PASS.

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(bsatn): opaque special types"
```

**Phase 1 done when:** `cabal test` is green with codec round-trip properties and error-path examples covering `UnexpectedEnd`, `InvalidBool`, `InvalidUtf8`, `UnknownVariant`, trailing bytes, and `decodeRows` index reporting.

---

# Phase 2 — v2 protocol

Produces `SpacetimeDB.Protocol.{RowList,Messages,Frame}`, pinned by hex fixtures. Depends only on Phase 1.

### Task 2.1: `BsatnRowList` splitting

**Files:**
- Create: `src/SpacetimeDB/Protocol/RowList.hs`
- Test: `test/SpacetimeDB/Protocol/RowListSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write failing test** — `test/SpacetimeDB/Protocol/RowListSpec.hs`

```haskell
module SpacetimeDB.Protocol.RowListSpec (spec) where

import qualified Data.ByteString as BS
import Test.Hspec
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.Protocol.RowList

spec :: Spec
spec = do
  describe "splitRows" $ do
    it "FixedSize chunks evenly" $
      splitRows (FixedSize 2) (BS.pack [1,2,3,4]) `shouldBe` [BS.pack [1,2], BS.pack [3,4]]
    it "FixedSize 0 means no rows" $
      splitRows (FixedSize 0) BS.empty `shouldBe` []
    it "RowOffsets slices at offsets, last runs to end" $
      splitRows (RowOffsets [0,2]) (BS.pack [1,2,3,4,5]) `shouldBe` [BS.pack [1,2], BS.pack [3,4,5]]
    it "RowOffsets empty means no rows" $
      splitRows (RowOffsets []) (BS.pack [1,2]) `shouldBe` []
  describe "decodeRowList" $
    it "reads hint + bytes and splits" $
      -- FixedSize(2) hint = sum tag 0, u16 2; then bytes: u32 len 4 + [1,2,3,4]
      runExact decodeRowList (BS.pack [0, 2,0, 4,0,0,0, 1,2,3,4])
        `shouldBe` Right [BS.pack [1,2], BS.pack [3,4]]
```

- [ ] **Step 2: Write `src/SpacetimeDB/Protocol/RowList.hs`**

```haskell
module SpacetimeDB.Protocol.RowList
  ( RowSizeHint (..)
  , splitRows
  , decodeRowList
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word16, Word64)
import SpacetimeDB.BSATN.Decoder

data RowSizeHint = FixedSize Word16 | RowOffsets [Word64]
  deriving (Eq, Show)

splitRows :: RowSizeHint -> ByteString -> [ByteString]
splitRows (FixedSize n) d
  | n == 0 || BS.null d = []
  | otherwise = go d
  where
    sz = fromIntegral n
    go bs | BS.null bs = []
          | otherwise  = let (h, t) = BS.splitAt sz bs in h : go t
splitRows (RowOffsets []) _ = []
splitRows (RowOffsets offs) d = zipWith slice starts ends
  where
    starts = map fromIntegral offs
    ends   = drop 1 starts ++ [BS.length d]
    slice s e = BS.take (e - s) (BS.drop s d)

decodeRowSizeHint :: Decoder RowSizeHint
decodeRowSizeHint = sumD $ \t -> case t of
  0 -> Right (FixedSize <$> u16)
  1 -> Right (RowOffsets <$> list u64)
  _ -> Left (UnknownVariant t)

-- | BsatnRowList = { size_hint, rows_data: Bytes } -> split rows.
decodeRowList :: Decoder [ByteString]
decodeRowList = do
  hint <- decodeRowSizeHint
  d    <- bytes
  pure (splitRows hint d)
```

- [ ] **Step 3: Wire into cabal + Spec.hs. Step 4: Run → PASS. Step 5: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(protocol): BsatnRowList splitting"
```

### Task 2.2: Nested server types (`QueryRows`, `QuerySetUpdate`, `TableUpdate`, `ReducerOutcome`, `ProcedureStatus`)

**Files:**
- Create: `src/SpacetimeDB/Protocol/Messages.hs`
- Test: `test/SpacetimeDB/Protocol/MessagesSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write failing test** — decode a `ReducerOutcome::Ok` with empty ret_value and no updates.

```haskell
module SpacetimeDB.Protocol.MessagesSpec (spec) where

import qualified Data.ByteString as BS
import Test.Hspec
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.Protocol.Messages

spec :: Spec
spec = do
  describe "reducerOutcome" $ do
    it "Ok with empty ret_value + no updates" $
      -- tag 0; ret_value bytes: u32 len 0; transaction_update: Array len 0
      runExact decodeReducerOutcome (BS.pack [0, 0,0,0,0, 0,0,0,0])
        `shouldBe` Right (OutcomeOk BS.empty [])
    it "OkEmpty is tag 1, zero payload" $
      runExact decodeReducerOutcome (BS.pack [1]) `shouldBe` Right OutcomeOkEmpty
    it "Err carries bytes" $
      runExact decodeReducerOutcome (BS.pack [2, 1,0,0,0, 9]) `shouldBe` Right (OutcomeErr (BS.pack [9]))
```

- [ ] **Step 2: Write `src/SpacetimeDB/Protocol/Messages.hs`** — data decls (from the shared reference) plus decoders for the nested types. Full module:

```haskell
module SpacetimeDB.Protocol.Messages
  ( Compression (..)
  , ServerMessage (..)
  , QueryRows (..), SingleTableRows (..)
  , QuerySetUpdate (..), TableUpdate (..), TableUpdateRows (..)
  , ReducerOutcome (..), ProcedureStatus (..)
  , decodeServerMessage
  , decodeReducerOutcome
  , ClientMessage (..)
  , encodeClientMessage
  , encodeSubscribe, encodeUnsubscribe, encodeOneOffQuery
  , encodeCallReducer, encodeCallProcedure
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import Data.Text (Text)
import Data.Word (Word8, Word32)
import SpacetimeDB.BSATN.Decoder
import SpacetimeDB.BSATN.Encoder
import SpacetimeDB.BSATN.Types
import SpacetimeDB.Protocol.RowList

data Compression = CompNone | CompBrotli | CompGzip deriving (Eq, Show)

data QueryRows = QueryRows [SingleTableRows] deriving (Eq, Show)
data SingleTableRows = SingleTableRows Text [ByteString] deriving (Eq, Show)
data QuerySetUpdate = QuerySetUpdate Word32 [TableUpdate] deriving (Eq, Show)
data TableUpdate = TableUpdate Text [TableUpdateRows] deriving (Eq, Show)
data TableUpdateRows = PersistentTable [ByteString] [ByteString] | EventTable [ByteString]
  deriving (Eq, Show)
data ReducerOutcome
  = OutcomeOk ByteString [QuerySetUpdate]
  | OutcomeOkEmpty
  | OutcomeErr ByteString
  | OutcomeInternalError Text
  deriving (Eq, Show)
data ProcedureStatus = ProcReturned ByteString | ProcInternalError Text deriving (Eq, Show)

data ServerMessage
  = InitialConnection Identity ConnectionId Text
  | SubscribeApplied Word32 Word32 QueryRows
  | UnsubscribeApplied Word32 Word32 (Maybe QueryRows)
  | SubscriptionError (Maybe Word32) Word32 Text
  | TransactionUpdate [QuerySetUpdate]
  | OneOffQueryResult Word32 (Either Text QueryRows)
  | ReducerResult Word32 Timestamp ReducerOutcome
  | ProcedureResult ProcedureStatus Timestamp TimeDuration Word32
  | Unhandled Word8
  deriving (Eq, Show)

decodeSingleTableRows :: Decoder SingleTableRows
decodeSingleTableRows = SingleTableRows <$> string <*> decodeRowList

decodeQueryRows :: Decoder QueryRows
decodeQueryRows = QueryRows <$> list decodeSingleTableRows

decodeTableUpdateRows :: Decoder TableUpdateRows
decodeTableUpdateRows = sumD $ \t -> case t of
  0 -> Right (PersistentTable <$> decodeRowList <*> decodeRowList)
  1 -> Right (EventTable <$> decodeRowList)
  _ -> Left (UnknownVariant t)

decodeTableUpdate :: Decoder TableUpdate
decodeTableUpdate = TableUpdate <$> string <*> list decodeTableUpdateRows

decodeQuerySetUpdate :: Decoder QuerySetUpdate
decodeQuerySetUpdate = QuerySetUpdate <$> u32 <*> list decodeTableUpdate

decodeReducerOutcome :: Decoder ReducerOutcome
decodeReducerOutcome = sumD $ \t -> case t of
  0 -> Right (OutcomeOk <$> bytes <*> list decodeQuerySetUpdate)
  1 -> Right (pure OutcomeOkEmpty)
  2 -> Right (OutcomeErr <$> bytes)
  3 -> Right (OutcomeInternalError <$> string)
  _ -> Left (UnknownVariant t)

decodeProcedureStatus :: Decoder ProcedureStatus
decodeProcedureStatus = sumD $ \t -> case t of
  0 -> Right (ProcReturned <$> bytes)
  1 -> Right (ProcInternalError <$> string)
  _ -> Left (UnknownVariant t)

decodeServerMessage :: Decoder ServerMessage
decodeServerMessage = sumD $ \t -> case t of
  0 -> Right (InitialConnection <$> decodeIdentity <*> decodeConnectionId <*> string)
  1 -> Right (SubscribeApplied <$> u32 <*> u32 <*> decodeQueryRows)
  2 -> Right (UnsubscribeApplied <$> u32 <*> u32 <*> optional decodeQueryRows)
  3 -> Right (SubscriptionError <$> optional u32 <*> u32 <*> string)
  4 -> Right (TransactionUpdate <$> list decodeQuerySetUpdate)
  5 -> Right (OneOffQueryResult <$> u32 <*> result string decodeQueryRows)
  6 -> Right (ReducerResult <$> u32 <*> decodeTimestamp <*> decodeReducerOutcome)
  7 -> Right (ProcedureResult <$> decodeProcedureStatus <*> decodeTimestamp
                              <*> decodeTimeDuration <*> u32)
  _ -> Right (pure (Unhandled t))

-- Client messages (filled in Task 2.4)
data ClientMessage
  = Subscribe Word32 Word32 [Text]
  | Unsubscribe Word32 Word32 Word8
  | OneOffQuery Word32 Text
  | CallReducer Word32 Word8 Text ByteString
  | CallProcedure Word32 Word8 Text ByteString
  deriving (Eq, Show)

encodeSubscribe :: Word32 -> Word32 -> [Text] -> B.Builder
encodeSubscribe rid qsid qs =
  encodeSum 0 (encodeU32 rid <> encodeU32 qsid <> encodeList qs encodeString)

encodeUnsubscribe :: Word32 -> Word32 -> Word8 -> B.Builder
encodeUnsubscribe rid qsid flags =
  encodeSum 1 (encodeU32 rid <> encodeU32 qsid <> encodeU8 flags)

encodeOneOffQuery :: Word32 -> Text -> B.Builder
encodeOneOffQuery rid q = encodeSum 2 (encodeU32 rid <> encodeString q)

encodeCallReducer :: Word32 -> Word8 -> Text -> ByteString -> B.Builder
encodeCallReducer rid flags name args =
  encodeSum 3 (encodeU32 rid <> encodeU8 flags <> encodeString name <> encodeBytes args)

encodeCallProcedure :: Word32 -> Word8 -> Text -> ByteString -> B.Builder
encodeCallProcedure rid flags name args =
  encodeSum 4 (encodeU32 rid <> encodeU8 flags <> encodeString name <> encodeBytes args)

encodeClientMessage :: ClientMessage -> B.Builder
encodeClientMessage m = case m of
  Subscribe rid qsid qs        -> encodeSubscribe rid qsid qs
  Unsubscribe rid qsid flags   -> encodeUnsubscribe rid qsid flags
  OneOffQuery rid q            -> encodeOneOffQuery rid q
  CallReducer rid f name args  -> encodeCallReducer rid f name args
  CallProcedure rid f name args-> encodeCallProcedure rid f name args
```

- [ ] **Step 3: Wire into cabal + Spec.hs. Step 4: Run → PASS. Step 5: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(protocol): server/client message decoders and encoders"
```

### Task 2.3: Client-message encoder byte-exact tests (incl. empty args and the `Subscribe` hex)

**Files:**
- Modify: `test/SpacetimeDB/Protocol/MessagesSpec.hs`

- [ ] **Step 1: Add failing tests**

```haskell
  describe "client encoders (byte-exact)" $ do
    it "Subscribe matches the documented hex" $
      let bs = runEncoder encodeClientMessage (Subscribe 1 1 [T.pack "SELECT * FROM widget"])
      in BS.unpack bs `shouldBe`
         [0x00, 1,0,0,0, 1,0,0,0, 1,0,0,0, 20,0,0,0]
         ++ map (fromIntegral . fromEnum) "SELECT * FROM widget"
    it "CallReducer with empty args ends in 00 00 00 00" $
      let bs = runEncoder encodeClientMessage (CallReducer 1 0 (T.pack "x") BS.empty)
      in drop (BS.length bs - 4) (BS.unpack bs) `shouldBe` [0,0,0,0]
```

Add imports `runEncoder` (from Encoder), `qualified Data.Text as T`.

- [ ] **Step 2: Run → PASS. Step 3: Commit**

```bash
git add test && git commit -m "test(protocol): byte-exact client encoders"
```

### Task 2.4: Frame decoding — compression byte + inflate + tag dispatch

**Files:**
- Create: `src/SpacetimeDB/Protocol/Frame.hs`
- Test: `test/SpacetimeDB/Protocol/FrameSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write failing test** — assemble an `InitialConnection` under tags 0 and 2 (gzip), and an unknown tag → `Unhandled`. Compress the fixture in-test with the same libs.

```haskell
module SpacetimeDB.Protocol.FrameSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Codec.Compression.GZip as GZip
import Test.Hspec
import SpacetimeDB.Protocol.Frame
import SpacetimeDB.Protocol.Messages

-- A minimal InitialConnection payload: tag 0, identity(32)=1, conn(16)=0, token "" (u32 0)
initialPayload :: BS.ByteString
initialPayload = BS.pack ([0] ++ (1 : replicate 31 0) ++ replicate 16 0 ++ [0,0,0,0])

spec :: Spec
spec = do
  it "tag 0 = uncompressed" $
    decodeFrame (BS.cons 0 initialPayload) `shouldBe`
      Right (InitialConnection (identityOf 1) (connOf 0) (txt ""))
  it "tag 2 = gzip" $ do
    let gz = BL.toStrict (GZip.compress (BL.fromStrict initialPayload))
    decodeFrame (BS.cons 2 gz) `shouldBe`
      Right (InitialConnection (identityOf 1) (connOf 0) (txt ""))
  it "empty frame errors" $ decodeFrame BS.empty `shouldBe` Left EmptyFrame
  it "unknown compression tag errors" $
    decodeFrame (BS.pack [9,0,0]) `shouldBe` Left (UnsupportedCompression 9)
```

(Helper `identityOf`/`connOf`/`txt` import the constructors from `SpacetimeDB.BSATN.Types`/`Data.Text`. Provide them in the test file.)

- [ ] **Step 2: Write `src/SpacetimeDB/Protocol/Frame.hs`**

```haskell
module SpacetimeDB.Protocol.Frame
  ( FrameError (..)
  , decodeFrame
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word8)
import qualified Codec.Compression.GZip as GZip
import qualified Codec.Compression.Brotli as Brotli
import Control.Exception (try, evaluate, SomeException)
import System.IO.Unsafe (unsafePerformIO)
import SpacetimeDB.BSATN.Decoder (DecodeError, runExact)
import SpacetimeDB.Protocol.Messages (ServerMessage, decodeServerMessage)

data FrameError
  = EmptyFrame
  | UnsupportedCompression Word8
  | BrotliFailed
  | GzipFailed
  | Bsatn DecodeError
  deriving (Eq, Show)

decodeFrame :: ByteString -> Either FrameError ServerMessage
decodeFrame frame = case BS.uncons frame of
  Nothing -> Left EmptyFrame
  Just (tag, payload) -> do
    raw <- inflate tag payload
    case runExact decodeServerMessage raw of
      Left e  -> Left (Bsatn e)
      Right m -> Right m

inflate :: Word8 -> ByteString -> Either FrameError ByteString
inflate 0 p = Right p
inflate 1 p = maybe (Left BrotliFailed) Right (safeLazy (Brotli.decompress (BL.fromStrict p)))
inflate 2 p = maybe (Left GzipFailed) Right (safeLazy (GZip.decompress (BL.fromStrict p)))
inflate t _ = Left (UnsupportedCompression t)

-- Decompressors throw on malformed input; force strictly and catch.
safeLazy :: BL.ByteString -> Maybe ByteString
safeLazy lbs = unsafePerformIO $ do
  r <- try (evaluate (BL.toStrict lbs)) :: IO (Either SomeException ByteString)
  pure (either (const Nothing) Just r)
{-# NOINLINE safeLazy #-}
```

- [ ] **Step 3: Wire into cabal + Spec.hs.** (Test suite deps already include `zlib`; add `brotli` to test `build-depends` too if the test needs it — here only `zlib`/`GZip` is used in the test.)

- [ ] **Step 4: Run → PASS. Step 5: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(protocol): frame decoding with compression"
```

### Task 2.5: Protocol fixtures for the tricky messages

**Files:**
- Modify: `test/SpacetimeDB/Protocol/FrameSpec.hs`

- [ ] **Step 1: Add fixtures** for: `SubscribeApplied` with a `FixedSize` row list; a `TransactionUpdate` with a `PersistentTable` (paired inserts/deletes) and an `EventTable`; `ReducerResult` in all four outcomes incl. `Ok` empty; a `ProcedureResult` (pins the id-last order); `OneOffQueryResult` ok and err; an unknown tag → `Unhandled`. Each is a hand-assembled `BS.pack [...]` prefixed with compression tag `0`, asserted via `decodeFrame`. Write each `it` with the exact byte list and the expected `ServerMessage` value.

- [ ] **Step 2: Run → PASS. Step 3: Commit**

```bash
git add test && git commit -m "test(protocol): fixtures for all server messages"
```

**Phase 2 done when:** every server message decodes from a hand-built frame (incl. `Ok` with empty `ret_value`, both row-hint kinds, unknown tag→`Unhandled`), and every client encoder is byte-exact.

---

# Phase 3 — client

Split into 3a (pure state + transitions, hermetic) and 3b (IO shell + reconnect). Endpoint/URL assembly is pure and tested here too.

### Task 3.1: Endpoint/URL assembly (pure)

**Files:**
- Create: `src/SpacetimeDB/Client/Endpoint.hs`
- Test: `test/SpacetimeDB/Client/EndpointSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write failing test**

```haskell
module SpacetimeDB.Client.EndpointSpec (spec) where

import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.Client.Endpoint
import SpacetimeDB.Protocol.Messages (Compression (..))

spec :: Spec
spec = do
  let base = HostPort (T.pack "localhost") 3000 False
  it "assembles the subscribe path with Brotli default" $
    subscribeUrl (EndpointConfig base (T.pack "mydb") CompBrotli Nothing)
      `shouldBe` T.pack "http://localhost:3000/v1/database/mydb/subscribe?compression=Brotli"
  it "adds confirmed when set" $
    subscribeUrl (EndpointConfig base (T.pack "mydb") CompGzip (Just False))
      `shouldBe` T.pack "http://localhost:3000/v1/database/mydb/subscribe?compression=Gzip&confirmed=false"
  it "secure host uses https and wss maps to https" $
    subscribeUrl (EndpointConfig (HostPort (T.pack "h") 443 True) (T.pack "d") CompNone Nothing)
      `shouldBe` T.pack "https://h:443/v1/database/d/subscribe?compression=None"
  it "base URI trims trailing slash and rewrites ws://" $
    subscribeUrl (EndpointConfig (BaseUri (T.pack "ws://proxy/stdb/")) (T.pack "d") CompBrotli Nothing)
      `shouldBe` T.pack "http://proxy/stdb/v1/database/d/subscribe?compression=Brotli"
```

- [ ] **Step 2: Write `src/SpacetimeDB/Client/Endpoint.hs`**

```haskell
module SpacetimeDB.Client.Endpoint
  ( Base (..)
  , EndpointConfig (..)
  , subscribeUrl
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import SpacetimeDB.Protocol.Messages (Compression (..))

data Base = HostPort Text Int Bool  -- host, port, secure
          | BaseUri Text
  deriving (Eq, Show)

data EndpointConfig = EndpointConfig
  { epBase        :: Base
  , epDatabase    :: Text
  , epCompression :: Compression
  , epConfirmed   :: Maybe Bool
  } deriving (Eq, Show)

subscribeUrl :: EndpointConfig -> Text
subscribeUrl (EndpointConfig base db comp confirmed) =
  root <> "/v1/database/" <> db <> "/subscribe?compression=" <> compName comp <> confirmedParam
  where
    root = case base of
      HostPort h p secure ->
        (if secure then "https://" else "http://") <> h <> ":" <> T.pack (show p)
      BaseUri u -> rewrite (T.dropWhileEnd (== '/') u)
    rewrite u
      | "wss://" `T.isPrefixOf` u = "https://" <> T.drop 6 u
      | "ws://"  `T.isPrefixOf` u = "http://"  <> T.drop 5 u
      | otherwise = u
    compName CompNone = "None"
    compName CompBrotli = "Brotli"
    compName CompGzip = "Gzip"
    confirmedParam = case confirmed of
      Nothing    -> ""
      Just True  -> "&confirmed=true"
      Just False -> "&confirmed=false"
```

- [ ] **Step 3: Wire into cabal + Spec.hs. Step 4: Run → PASS. Step 5: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(client): endpoint URL assembly"
```

### Task 3.2: Client public types (`Event`, `ClientError`, reply taxonomies)

**Files:**
- Create: `src/SpacetimeDB/Client/Types.hs`
- Modify: `hs-spacetime.cabal`
- Test: (covered indirectly by later specs; no dedicated spec — this is a data-declaration module)

- [ ] **Step 1: Write `src/SpacetimeDB/Client/Types.hs`** (exactly the shared reference types)

```haskell
module SpacetimeDB.Client.Types
  ( Event (..)
  , ClientError (..)
  , RowBatch (..)
  , ReducerReply (..)
  , ProcedureReply (..)
  , QueryReply (..)
  , formatEvent
  , formatError
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8, Word32)
import SpacetimeDB.BSATN.Decoder (DecodeError)
import SpacetimeDB.BSATN.Types (Identity, ConnectionId)

data RowBatch = BatchInitial | BatchInsert | BatchDelete deriving (Eq, Show)

data Event
  = Connected Identity ConnectionId Text
  | Disconnected Text
  | Reconnecting Int Int
  | InitialRows Text [ByteString]
  | Changed Text [ByteString] [ByteString]
  | SubscriptionFailed Word32 Text
  | Unsubscribed Word32
  | UnhandledMessage Word8
  | UnmatchedReply Word32
  deriving (Eq, Show)

data ClientError
  = HandshakeFailed Text
  | DecodeFailed Text
  | SendFailed Text
  | RowDecodeFailed Text RowBatch Int DecodeError
  | CallFailed Text Text
  deriving (Eq, Show)

data ReducerReply a e = Returned a | ReturnedNothing | Failed e | ReducerCallFailed Text
  deriving (Eq, Show)
data ProcedureReply a = ProcReturnedVal a | ProcedureCallFailed Text deriving (Eq, Show)
data QueryReply = QueryReturned [(Text, [ByteString])] | QueryRejected Text | QueryCallFailed Text
  deriving (Eq, Show)

formatEvent :: Event -> Text
formatEvent e = case e of
  Connected _ _ _        -> "connected"
  Disconnected r         -> "disconnected: " <> r
  Reconnecting a d       -> "reconnecting attempt " <> T.pack (show a) <> " in " <> T.pack (show d) <> "ms"
  InitialRows t rs       -> "initial " <> t <> " (" <> T.pack (show (length rs)) <> " rows)"
  Changed t ins del      -> "changed " <> t <> " (+" <> T.pack (show (length ins))
                              <> " -" <> T.pack (show (length del)) <> ")"
  SubscriptionFailed q m -> "subscription " <> T.pack (show q) <> " failed: " <> m
  Unsubscribed q         -> "unsubscribed " <> T.pack (show q)
  UnhandledMessage tag   -> "unhandled message tag " <> T.pack (show tag)
  UnmatchedReply rid     -> "unmatched reply " <> T.pack (show rid)

formatError :: ClientError -> Text
formatError err = case err of
  HandshakeFailed r      -> "handshake failed: " <> r
  DecodeFailed r         -> "decode failed: " <> r
  SendFailed r           -> "send failed: " <> r
  RowDecodeFailed q _ i _ -> "row decode failed for " <> q <> " at index " <> T.pack (show i)
  CallFailed n r         -> "call " <> n <> " failed: " <> r
```

- [ ] **Step 2: Wire into cabal. Step 3: Build → OK. Step 4: Commit**

```bash
git add src hs-spacetime.cabal && git commit -m "feat(client): public event/error/reply types"
```

### Task 3.3: Pure `ClientState` + call correlation transitions

**Files:**
- Create: `src/SpacetimeDB/Client/State.hs`
- Test: `test/SpacetimeDB/Client/StateSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

`ClientState` is pure. A **pending call** stores a continuation, but for hermetic testing we keep continuations abstract by storing a `PendingKind` tag we can assert on. The IO shell (Task 3.6) supplies real continuations via the same API.

- [ ] **Step 1: Write failing test** — allocation, reply routing, drain, unmatched.

```haskell
module SpacetimeDB.Client.StateSpec (spec) where

import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.Client.State

spec :: Spec
spec = do
  describe "call correlation" $ do
    it "allocateCall hands out increasing ids and records pending" $ do
      let s0 = emptyState
          (s1, r1) = allocateCall s0 (T.pack "add")
          (s2, r2) = allocateCall s1 (T.pack "add")
      (r1, r2) `shouldBe` (1, 2)
      M.keys (pendingCalls s2) `shouldBe` [1,2]
    it "takePending removes and returns the name" $ do
      let (s1, rid) = allocateCall emptyState (T.pack "add")
          (s2, nm)  = takePending s1 rid
      (nm, M.member rid (pendingCalls s2)) `shouldBe` (Just (T.pack "add"), False)
    it "takePending on unknown id yields Nothing" $
      snd (takePending emptyState 99) `shouldBe` M.member (99::Int) (pendingCalls emptyState)
    it "drainPending clears everything" $ do
      let (s1, _) = allocateCall emptyState (T.pack "a")
          (s2, _) = allocateCall s1 (T.pack "b")
          (s3, drained) = drainPending s2
      (map fst drained, M.null (pendingCalls s3)) `shouldBe` ([1,2], True)
```

(Adjust the `takePending`-unknown test to your final `Maybe` shape — the intent is: unknown id returns `Nothing` and leaves the map unchanged.)

- [ ] **Step 2: Write `src/SpacetimeDB/Client/State.hs`** (pending values are the call name here; the IO layer keys real continuations by the same id in its own map)

```haskell
module SpacetimeDB.Client.State
  ( ClientState (..)
  , LiveSub (..)
  , emptyState
  , allocateCall, takePending, drainPending
  , allocateSub, forgetSub, subForId
  , learnToken
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Word (Word32)

data LiveSub = LiveSub
  { subQuerySetId :: Word32
  , subQuery      :: Text
  , subTable      :: Maybe Text   -- typed subscriptions carry a table name
  } deriving (Eq, Show)

data ClientState = ClientState
  { token          :: Maybe Text
  , subscriptions  :: [LiveSub]
  , nextQuerySetId :: Word32
  , pendingCalls   :: Map Int Text   -- request_id -> call name
  , nextRequestId  :: Int
  } deriving (Eq, Show)

emptyState :: ClientState
emptyState = ClientState Nothing [] 1 M.empty 1

allocateCall :: ClientState -> Text -> (ClientState, Int)
allocateCall s name =
  let rid = nextRequestId s
  in ( s { nextRequestId = rid + 1
         , pendingCalls = M.insert rid name (pendingCalls s) }
     , rid )

takePending :: ClientState -> Int -> (ClientState, Maybe Text)
takePending s rid = case M.lookup rid (pendingCalls s) of
  Nothing -> (s, Nothing)
  Just nm -> (s { pendingCalls = M.delete rid (pendingCalls s) }, Just nm)

drainPending :: ClientState -> (ClientState, [(Int, Text)])
drainPending s = (s { pendingCalls = M.empty }, M.toList (pendingCalls s))

-- | Allocate a new subscription id (monotonic, never reused).
allocateSub :: ClientState -> Text -> Maybe Text -> (ClientState, LiveSub)
allocateSub s query tbl =
  let qsid = nextQuerySetId s
      sub  = LiveSub qsid query tbl
  in (s { nextQuerySetId = qsid + 1, subscriptions = subscriptions s ++ [sub] }, sub)

forgetSub :: ClientState -> Word32 -> ClientState
forgetSub s qsid = s { subscriptions = filter ((/= qsid) . subQuerySetId) (subscriptions s) }

subForId :: ClientState -> Word32 -> Maybe LiveSub
subForId s qsid = case filter ((== qsid) . subQuerySetId) (subscriptions s) of
  (x:_) -> Just x
  []    -> Nothing

learnToken :: ClientState -> Text -> ClientState
learnToken s t = s { token = Just t }
```

- [ ] **Step 3: Wire into cabal + Spec.hs. Step 4: Run → PASS. Step 5: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(client): pure ClientState and call correlation"
```

### Task 3.4: Subscription-id allocation properties (monotonic, no reuse)

**Files:**
- Modify: `test/SpacetimeDB/Client/StateSpec.hs`

- [ ] **Step 1: Add failing tests**

```haskell
  describe "subscription ids" $ do
    it "start at 1 and increase; forget never lowers next" $ do
      let (s1, a) = allocateSub emptyState (T.pack "q1") Nothing
          (s2, b) = allocateSub s1 (T.pack "q2") Nothing
          s3      = forgetSub s2 (subQuerySetId a)
          (_, c)  = allocateSub s3 (T.pack "q3") Nothing
      map subQuerySetId [a,b,c] `shouldBe` [1,2,3]
    it "subForId finds live subs and misses forgotten ones" $ do
      let (s1, a) = allocateSub emptyState (T.pack "q1") Nothing
          s2      = forgetSub s1 (subQuerySetId a)
      (subForId s1 1, subForId s2 1) `shouldBe` (Just a, Nothing)
```

- [ ] **Step 2: Run → PASS. Step 3: Commit**

```bash
git add test && git commit -m "test(client): subscription id allocation invariants"
```

### Task 3.5: Row dispatch decision (pure) — typed vs raw path, empty-op suppression

**Files:**
- Create: `src/SpacetimeDB/Client/Dispatch.hs`
- Test: `test/SpacetimeDB/Client/DispatchSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

The pure decision: given the live subscription list and a table op, produce a list of *dispatch actions* (`ToTyped table query rows | ToRaw event`) with empty ops suppressed. The IO layer turns actions into callback invocations. This keeps "which path, is it suppressed, newest-wins routing" testable without callbacks.

- [ ] **Step 1: Write failing test** — `test/SpacetimeDB/Client/DispatchSpec.hs`

```haskell
module SpacetimeDB.Client.DispatchSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.Client.Dispatch
import SpacetimeDB.Client.State (LiveSub (..))
import SpacetimeDB.Protocol.Messages

spec :: Spec
spec = do
  let widgetSub = LiveSub 1 (T.pack "SELECT * FROM widget") (Just (T.pack "widget"))
      row = BS.pack [1]
  describe "routeTableUpdate" $ do
    it "sends to typed dispatcher when a sub owns the table" $
      routeTableUpdate [widgetSub] (TableUpdate (T.pack "widget") [PersistentTable [row] []])
        `shouldBe` [ToTyped (T.pack "widget") (T.pack "SELECT * FROM widget") [row] []]
    it "sends to raw path when no typed sub owns the table" $
      routeTableUpdate [] (TableUpdate (T.pack "other") [PersistentTable [row] []])
        `shouldBe` [ToRaw (Changed' (T.pack "other") [row] [])]
    it "suppresses empty persistent ops" $
      routeTableUpdate [] (TableUpdate (T.pack "other") [PersistentTable [] []]) `shouldBe` []
    it "event tables map to inserts-only Changed" $
      routeTableUpdate [widgetSub] (TableUpdate (T.pack "widget") [EventTable [row]])
        `shouldBe` [ToTyped (T.pack "widget") (T.pack "SELECT * FROM widget") [row] []]
```

- [ ] **Step 2: Write `src/SpacetimeDB/Client/Dispatch.hs`**

```haskell
module SpacetimeDB.Client.Dispatch
  ( DispatchAction (..)
  , RawOp (..)
  , routeTableUpdate
  , routeInitial
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.List (find)
import SpacetimeDB.Client.State (LiveSub (..))
import SpacetimeDB.Protocol.Messages

data RawOp = Initial' Text [ByteString] | Changed' Text [ByteString] [ByteString]
  deriving (Eq, Show)

data DispatchAction
  = ToTyped Text Text [ByteString] [ByteString]   -- table, query, inserts, deletes
  | ToRaw RawOp
  deriving (Eq, Show)

-- newest typed sub wins for a given table
typedSubFor :: [LiveSub] -> Text -> Maybe LiveSub
typedSubFor subs tbl =
  find (\s -> subTable s == Just tbl) (reverse subs)

routeTableUpdate :: [LiveSub] -> TableUpdate -> [DispatchAction]
routeTableUpdate subs (TableUpdate tbl rowsList) =
  concatMap (opFor tbl) rowsList
  where
    opFor t (PersistentTable ins del) = emit t ins del
    opFor t (EventTable evs)          = emit t evs []
    emit t ins del
      | null ins && null del = []
      | otherwise = case typedSubFor subs t of
          Just s  -> [ToTyped t (subQuery s) ins del]
          Nothing -> [ToRaw (Changed' t ins del)]

routeInitial :: [LiveSub] -> SingleTableRows -> [DispatchAction]
routeInitial subs (SingleTableRows tbl rows) =
  case typedSubFor subs tbl of
    Just s  -> [ToTyped tbl (subQuery s) rows []]
    Nothing -> [ToRaw (Initial' tbl rows)]
```

- [ ] **Step 3: Wire into cabal + Spec.hs. Step 4: Run → PASS. Step 5: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(client): pure row dispatch routing"
```

### Task 3.6: IO shell — connection, reader/writer, reconnect loop, builder & handle

**Files:**
- Create: `src/SpacetimeDB/Client.hs`
- Create: `src/SpacetimeDB/Client/Connection.hs`
- Modify: `src/SpacetimeDB.hs` (re-export the public API)
- Modify: `hs-spacetime.cabal` (add both modules; add `network`, `websockets`, `wuss` already present)
- Test: deferred to Task 3.7 (closed-port) and Phase 6 (live)

This is the one module that does IO. It holds:

```haskell
data Client = Client
  { clState    :: TVar ClientState
  , clConn     :: TVar (Maybe Connection)   -- current live socket abstraction
  , clOutbound :: TQueue Builder            -- serialised sends
  , clCallCbs  :: TVar (Map Int CallCont)   -- request_id -> real continuation
  , clOnEvent  :: TVar (Event -> IO ())
  , clOnError  :: TVar (ClientError -> IO ())
  , clConfig   :: Config
  , clStop     :: TVar Bool
  , clSup      :: TVar (Maybe (Async ()))   -- supervisor handle
  }
```

- [ ] **Step 1: Write `SpacetimeDB/Client/Connection.hs`** implementing:
  - `Config` record (endpoint, token, compression, confirmed, reconnect policy, builder-declared subs, callbacks).
  - `ReconnectPolicy = NoReconnect | Reconnect { initialMs :: Int, maxMs :: Int, maxAttempts :: Maybe Int }`.
  - `CallCont` = a function `ReplyPayload -> IO ()` where `ReplyPayload` is a sum over the raw reducer/procedure/one-off results (so `Client.hs`'s typed wrappers build the decoding closure).
  - `runSupervisor :: Client -> IO ()` — the recursive reconnect loop:
    ```
    loop backoff = do
      stop <- readTVarIO (clStop client)
      if stop then pure () else do
        r <- try (withConnection client (\conn ->
                race_ (readerLoop client conn) (writerLoop client conn)))
        case r of
          Right () -> pure ()                       -- clean stop path sets clStop
          Left (e :: SomeException) -> do
            handleDisconnect client (T.pack (show e))
            case reconnectPolicy of
              NoReconnect -> pure ()
              Reconnect{..} -> maybeRetry ...        -- emit Reconnecting, threadDelay, loop (min max (backoff*2))
    ```
  - `withConnection` = `bracket` opening the websocket via `wuss`/`websockets` using `subscribeUrl` + the `Sec-WebSocket-Protocol: v2.bsatn.spacetimedb` header + optional `Authorization`, and on open: replay all subscriptions from `clState` under their ids (enqueue `encodeSubscribe`), then run the body; teardown closes the socket.
  - `readerLoop` = `receiveData` → `decodeFrame` → `handleServerMessage`. A decode error fires `DecodeFailed` and continues; a `receiveData` exception propagates (kills the connection → supervisor reconnects).
  - `writerLoop` = `atomically (readTQueue clOutbound)` → `sendBinaryData`.
  - `handleServerMessage` implements the ordering rules using the pure functions: on `InitialConnection` → `learnToken` into state, fire `Connected`; on row-carrying messages → build dispatch actions via `SpacetimeDB.Client.Dispatch` and run callbacks; on `ReducerResult`/`ProcedureResult`/`OneOffQueryResult` → dispatch embedded rows first (reducer only), then look up the call continuation in `clCallCbs`, run it, remove it; unknown reply id → `UnmatchedReply`; `SubscribeApplied`/`UnsubscribeApplied`/`SubscriptionError` → events + `forgetSub` as appropriate; `Unhandled` → `UnhandledMessage`.
  - `handleDisconnect` = fire `Disconnected`, `atomically` drain `clCallCbs` (running each with a `CallFailed`), clear `clConn`.

  Write the full module. Where the skill's rules are subtle (reducer rows before reply; one-off rows bypass routing; runtime add while disconnected just joins the list), implement exactly as the spec §Layer 3 states.

- [ ] **Step 2: Write `SpacetimeDB/Client.hs`** — the builder and handle:
  - `builder :: Text -> Int -> Text -> Config` (host, port, database) and `withSecure`, `withBaseUri`, `withToken`, `withCompression`, `withConfirmedReads`, `withReconnect`, `subscribe`, `subscribeQuery`, `onEvent`, `onError`.
  - `start :: Config -> IO (Either Text Client)` — allocate builder subs into `ClientState` (ids 1..n), spawn the supervisor with `async`; with `NoReconnect`, block on the first connect result and return `Left` on failure; with reconnect, return `Right` immediately.
  - `stop`, `token` (STM read), `addSubscription`/`addQuerySubscription` (STM: `allocateSub`, tell the connection to send now if greeted else rely on replay, return handle), `unsubscribe` (STM `forgetSub` + enqueue `encodeUnsubscribe` if greeted), `subscriptionId`, `callReducer`, `callProcedure`, `oneOffQuery` (allocate via `allocateCall`, store continuation in `clCallCbs`, enqueue frame; if no connection, immediately run continuation with `CallFailed "not connected"`).
  - Document the threading contract in haddocks on every callback-taking function.

- [ ] **Step 3: Update `src/SpacetimeDB.hs`** to re-export the public surface:

```haskell
module SpacetimeDB
  ( module SpacetimeDB.Client
  , module SpacetimeDB.Client.Types
  , module SpacetimeDB.BSATN.Types
  ) where

import SpacetimeDB.Client
import SpacetimeDB.Client.Types
import SpacetimeDB.BSATN.Types
```

- [ ] **Step 4: Build (no new tests yet)**

Run: `nix develop .#dev --command cabal build all`
Expected: compiles.

- [ ] **Step 5: Commit**

```bash
git add src hs-spacetime.cabal && git commit -m "feat(client): IO shell, reconnect loop, builder and handle"
```

### Task 3.7: Closed-port failure-path tests

**Files:**
- Create: `test/SpacetimeDB/Client/ConnectionSpec.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write failing test** — point at a closed port (pick a high port nothing listens on).

```haskell
module SpacetimeDB.Client.ConnectionSpec (spec) where

import Control.Concurrent.STM
import Control.Concurrent (threadDelay)
import Data.IORef
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.Client
import SpacetimeDB.Client.Types

spec :: Spec
spec = do
  it "NoReconnect: start returns HandshakeFailed against a closed port" $ do
    r <- start (builder (T.pack "127.0.0.1") 59999 (T.pack "nodb")
                  & withReconnect NoReconnect)
    case r of
      Left _  -> pure ()
      Right _ -> expectationFailure "expected handshake failure"
  it "Reconnect: start succeeds and emits Reconnecting(1)" $ do
    seen <- newIORef []
    r <- start (builder (T.pack "127.0.0.1") 59999 (T.pack "nodb")
                  & withReconnect (Reconnect 50 200 (Just 1))
                  & onEvent (\e -> modifyIORef seen (e:)))
    case r of
      Left _  -> expectationFailure "expected a handle"
      Right c -> do threadDelay 300000; stop c
    evs <- readIORef seen
    any isReconnecting evs `shouldBe` True
  where
    isReconnecting (Reconnecting 1 _) = True
    isReconnecting _ = False
```

(`&` from `Data.Function`; add the import. Expect connection-refused noise in the log — note it in the README per the spec.)

- [ ] **Step 2: Run → PASS (may need small timing adjustments). Step 3: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "test(client): closed-port handshake and reconnect paths"
```

**Phase 3 done when:** pure state/dispatch/endpoint specs are green and the closed-port tests pass; `cabal build all` compiles the full client.

---

# Phase 4 — codegen

Pure `RawModuleDefV10 JSON -> Either Error Text`, thin CLI, goldens.

### Task 4.1: Schema model + JSON parsing (`Typespace`, `Types`, `Tables`, `Reducers`, `Procedures`, `ExplicitNames`)

**Files:**
- Create: `src/SpacetimeDB/Codegen/Schema.hs`
- Test: `test/SpacetimeDB/Codegen/SchemaSpec.hs`
- Test fixture: `test/fixtures/sample.schema.json` (captured; see note)
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

> **Fixture note:** per the spec, fixtures are *captured* `spacetime describe --json` output, never hand-written. Until Phase 6 stands up a server, use a **small captured** file. If no capture is available yet, the executor should: (a) do Phase 6 Task 6.1–6.2 first to get a running server, capture `sample.schema.json` from a purpose-built module, then return here. Mark this dependency explicitly. Do **not** hand-write the JSON.

- [ ] **Step 1: Write `src/SpacetimeDB/Codegen/Schema.hs`** with the model from the spec (`Typ`, `Field`, `Variant`, `Table`, `Reducer`, `Procedure`, `Module`) and an aeson parser that indexes the tagged sections by key, parses `AlgebraicType` (single-key tagged object), and `resolve :: Module -> Typ -> Either Text Typ` following refs. Provide `parseModule :: BL.ByteString -> Either String Module`.

- [ ] **Step 2: Write failing test** — parse the captured fixture, assert the table names, a reducer's params, and that `resolve` follows a `Ref` to a product.

- [ ] **Step 3: Run → PASS. Step 4: Commit**

```bash
git add src test hs-spacetime.cabal test/fixtures && git commit -m "feat(codegen): V10 schema model and parser"
```

### Task 4.2: Shape recognition + the fixpoint (named/dropped)

**Files:**
- Modify: `src/SpacetimeDB/Codegen/Schema.hs`
- Test: `test/SpacetimeDB/Codegen/SchemaSpec.hs`

- [ ] **Step 1: Add** `classify :: Module -> Typ -> Shape` implementing the ordered recognition (Ref→named, Ref→dropped, primitive, Array, unit, special product, transparent wrapper, Option, otherwise-anonymous error) and `computeNamedDropped :: Module -> Module` running the fixpoint (register candidates as named, try to generate each — using a dry-run of the emit logic or a `canRender` predicate — drop failures, repeat until stable). Test: a product depending on a dropped type ends up dropped; a supported enum ends up named.

- [ ] **Step 2: Run → PASS. Step 3: Commit**

```bash
git add src test && git commit -m "feat(codegen): shape recognition and named/dropped fixpoint"
```

### Task 4.3: Emit records, decoders, encoders, enums

**Files:**
- Create: `src/SpacetimeDB/Codegen.hs`
- Test: `test/SpacetimeDB/Codegen/GoldenSpec.hs`
- Test fixture golden: `test/golden/sample_generated.hs`
- Modify: `hs-spacetime.cabal`, `test/Spec.hs`

- [ ] **Step 1: Write `src/SpacetimeDB/Codegen.hs`** — `generate :: Bool -> Module -> Either [Text] Text` (the `Bool` is `--skip`). Emit, in order, tables by name → declared types in schema order → callables by name. Each block uses the codec combinators: a record type; a decoder `snake(name) :: Decoder T` reading fields in order with `<$>`/`<*>`; an encoder `encodeSnake(name) :: Encoder T` = `\v -> concatE [...]`. Sums → tagged unions with a `sumD` decoder and `encodeSum` encoder. Deterministic layout (fixed import block, one field per line for records, trailing-comma list style). Fatal (Left) on unsupported unless skip; skip records `//// Skipped` header lines.

- [ ] **Step 2: Generate the golden** by running the generator over the captured fixture and committing the output; then the test asserts byte-for-byte equality:

```haskell
module SpacetimeDB.Codegen.GoldenSpec (spec) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Test.Hspec
import SpacetimeDB.Codegen
import SpacetimeDB.Codegen.Schema

spec :: Spec
spec = do
  it "sample fixture matches the committed golden" $ do
    raw <- BL.readFile "test/fixtures/sample.schema.json"
    golden <- TIO.readFile "test/golden/sample_generated.hs"
    let Right m = parseModule raw
    generate False (computeNamedDropped m) `shouldBe` Right golden
```

- [ ] **Step 3: Run → PASS. Step 4: `fourmolu --check` the golden** (must be idempotent).

Run: `nix develop .#dev --command fourmolu --mode check test/golden/sample_generated.hs`
Expected: no diff.

- [ ] **Step 5: Commit**

```bash
git add src test hs-spacetime.cabal && git commit -m "feat(codegen): emit records/decoders/encoders/enums with golden"
```

### Task 4.4: Emit typed reducer/procedure wrappers; drop `Private`

**Files:**
- Modify: `src/SpacetimeDB/Codegen.hs`
- Test: `test/SpacetimeDB/Codegen/GoldenSpec.hs` (extend the golden)

- [ ] **Step 1:** Emit one function per **ClientCallable** reducer (`client -> <named params in wire order> -> (ReducerReply ok err -> IO ()) -> IO ()`, body encodes params into args and calls `callReducer` with the canonical name and generated ok/err decoders) and procedure (single return decoder, `callProcedure`). Drop `Private` callables silently. Use `ExplicitNames.canonical_name` in the string literal, source name for the function name. Regenerate + extend the golden; assert equality and that no `init` wrapper appears.

- [ ] **Step 2: Run → PASS. Step 3: Commit**

```bash
git add src test && git commit -m "feat(codegen): typed reducer/procedure wrappers"
```

### Task 4.5: CLI executable + generated-type round-trip test

**Files:**
- Create: `app/Codegen.hs`
- Modify: `hs-spacetime.cabal` (add `executable hs-spacetime-codegen`)
- Test: `test/SpacetimeDB/Codegen/GeneratedRoundtripSpec.hs` (imports the committed golden module and round-trips its types)

- [ ] **Step 1: Add executable stanza**

```
executable hs-spacetime-codegen
  import:           warnings
  hs-source-dirs:   app
  main-is:          Codegen.hs
  default-language: Haskell2010
  build-depends:    base, hs-spacetime, bytestring, text
```

- [ ] **Step 2: Write `app/Codegen.hs`** — read stdin, `parseModule`, `computeNamedDropped`, `generate skip`, on `Left` print offenders to stderr and exit 1 (unless `--skip`), on `Right` write to the file arg or stdout.

```haskell
module Main (main) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import SpacetimeDB.Codegen
import SpacetimeDB.Codegen.Schema

main :: IO ()
main = do
  args <- getArgs
  let skip = "--skip" `elem` args
      outs = filter (/= "--skip") args
  raw <- BL.getContents
  case parseModule raw of
    Left e -> hPutStrLn stderr ("schema parse error: " ++ e) >> exitFailure
    Right m -> case generate skip (computeNamedDropped m) of
      Left errs -> mapM_ (hPutStrLn stderr . show) errs >> exitFailure
      Right src -> case outs of
        (f:_) -> TIO.writeFile f src
        []    -> TIO.putStr src
```

- [ ] **Step 3:** Add a generated-type round-trip spec that imports the committed `sample_generated.hs` (add it as an `other-modules` in the test suite, pointing `hs-source-dirs` to include `test/golden`), builds a value, and checks `decode (encode x) == x` for a couple of the generated types.

- [ ] **Step 4: Run → PASS. Step 5: Commit**

```bash
git add app src test hs-spacetime.cabal && git commit -m "feat(codegen): CLI executable and generated-type round-trip"
```

**Phase 4 done when:** goldens match byte-for-byte, generated types round-trip, `fourmolu --check` passes on generated output, and the CLI reads stdin → source.

---

# Phase 5 — (folded into 3 and 4)

No separate phase; the client IO shell (Phase 3) and codegen (Phase 4) are complete. Proceed to the live suite.

---

# Phase 6 — live harness, fixture module, integration checks

Opt-in (`SPACETIMEDB_INTEGRATION=1`). Uses the `live` dev shell.

### Task 6.1: Finalize the `spacetime` package attribute in the flake

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Discover the attribute**

Run: `nix flake show github:clockworklabs/SpacetimeDB`
Read the output; identify the package that provides the `spacetime` CLI (likely `packages.<system>.default` or a named `spacetimedb`/`cli` attribute).

- [ ] **Step 2:** Set `spacetimeCli = spacetimedb.packages.${system}.<attr>;` in `flake.nix` to the discovered attribute. Verify:

Run: `nix develop .#live --command spacetime --version`
Expected: prints a version.

- [ ] **Step 3: Commit**

```bash
git add flake.nix flake.lock && git commit -m "chore(nix): wire spacetime CLI into the live shell"
```

### Task 6.2: The Rust fixture module

**Files:**
- Create: `fixture/Cargo.toml`
- Create: `fixture/src/lib.rs`

- [ ] **Step 1: Write `fixture/src/lib.rs`** (exactly the spec's fixture)

```rust
use spacetimedb::{table, reducer, ReducerContext, Table};

#[table(name = widget, public)]
pub struct Widget {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    pub name: String,
    pub quantity: u32,
}

#[reducer(init)]
pub fn init(ctx: &ReducerContext) {
    ctx.db.widget().insert(Widget { id: 0, name: "seed".into(), quantity: 1 });
}

#[reducer]
pub fn add_widget(ctx: &ReducerContext, name: String, quantity: u32) {
    ctx.db.widget().insert(Widget { id: 0, name, quantity });
}
```

- [ ] **Step 2: Write `fixture/Cargo.toml`** — a `cdylib` crate depending on `spacetimedb` (version matching the CLI). Verify it builds:

Run: `nix develop .#live --command spacetime build --project-path fixture`
Expected: produces a wasm module. (First build is slow.)

- [ ] **Step 3: Commit**

```bash
git add fixture && git commit -m "test(live): rust fixture module (widget/init/add_widget)"
```

### Task 6.3: The harness script (`serve` / `describe` / `regenerate`)

**Files:**
- Create: `scripts/live-harness.sh`

- [ ] **Step 1: Write the script** with the three modes from the spec: `serve` (build wasm, pick a free port, throwaway `--root-dir`/`--data-dir`, `--in-memory`, poll `/v1/ping`, publish, print `READY <port> <database> <root>`, then block on `read` from stdin; `EXIT` trap and `trap 'exit' INT TERM HUP PIPE` kill the server and `rm -rf` the temp dir; build before starting the server), `describe <root> <port> <db>` (capture stderr, release only on failure), `regenerate [out]` (serve-style boot → pipe `describe` through `cabal run -v0 hs-spacetime-codegen` → write the live golden → tear down). Make it executable.

- [ ] **Step 2: Smoke test**

Run: `nix develop .#live --command bash -c 'echo | scripts/live-harness.sh serve'`
Expected: prints `READY <port> <db> <root>` then exits cleanly on EOF, leaving no server or temp dir behind.

- [ ] **Step 3: Commit**

```bash
git add scripts && git commit -m "test(live): server harness (serve/describe/regenerate)"
```

### Task 6.4: Capture `sample.schema.json` + live golden; close the Phase 4 fixture dependency

**Files:**
- Create/Update: `test/fixtures/sample.schema.json`
- Create: `test/golden/fixture_generated.hs`

- [ ] **Step 1:** Capture the schema and generate the live golden:

Run: `nix develop .#live --command bash scripts/live-harness.sh regenerate test/golden/fixture_generated.hs`
Then capture the raw schema too (for the hermetic `sample.schema.json` used by Phase 4): describe the same server and save the JSON.

- [ ] **Step 2:** If Phase 4 used a placeholder, re-run Phase 4 golden generation now against this real capture so the hermetic goldens are from captured output. Ensure `cabal test` (hermetic) still passes.

- [ ] **Step 3: Commit**

```bash
git add test/fixtures test/golden && git commit -m "test: capture live schema fixtures and golden"
```

### Task 6.5: TCP proxy + integration checks

**Files:**
- Create: `test/SpacetimeDB/IntegrationCheck.hs`
- Create: `test/SpacetimeDB/Live/Proxy.hs`
- Modify: `test/Spec.hs` (gate on `SPACETIMEDB_INTEGRATION`), `hs-spacetime.cabal`

- [ ] **Step 1: Write `test/SpacetimeDB/Live/Proxy.hs`** — a throwaway TCP proxy: listens on a local port, forwards to the server, `cut` closes all live connections (waits for forwarding threads to die before returning) while staying open for reconnects, `connections` returns the count of connections it has carried. Use `network` + `async`.

- [ ] **Step 2: Write `test/SpacetimeDB/IntegrationCheck.hs`** — the 8 ordered checks from the spec as functions named `*_check` (so hspec-discover-style naming never picks them; here we control the runner anyway). Each boots against the shared harness server (started once by a top-level helper), exercises the client, and asserts events in order.

- [ ] **Step 3: Gate the runner in `test/Spec.hs`**

```haskell
main = do
  integ <- lookupEnv "SPACETIMEDB_INTEGRATION"
  hspec $ do
    describe "..." ...            -- all hermetic specs
    case integ of
      Just "1" -> describe "live" liveChecks
      _        -> pure ()
```

The live helper starts the harness (`serve`) as a child whose stdin is a pipe from the test process, reads the `READY` line, shares the port/db across checks, and closes the pipe at the end.

- [ ] **Step 4: Run the live suite**

Run: `SPACETIMEDB_INTEGRATION=1 nix develop .#live --command cabal test --test-show-details=direct`
Expected: all 8 checks pass; hermetic run (`nix develop .#dev --command cabal test`) still shows zero live checks.

- [ ] **Step 5: Commit**

```bash
git add test hs-spacetime.cabal && git commit -m "test(live): TCP proxy and 8 integration checks"
```

**Phase 6 done when:** `SPACETIMEDB_INTEGRATION=1 … cabal test` passes all checks; the default `cabal test` stays hermetic.

---

# Phase 7 — flake / CI / README polish

### Task 7.1: fourmolu config + format the whole tree

**Files:**
- Create: `fourmolu.yaml`
- (Format) all `src/`, `test/`, `app/`

- [ ] **Step 1: Write `fourmolu.yaml`** (a conventional config: 2-space indent, trailing commas leading style, etc. — whatever the generated code already matches, so `--check` is idempotent on both hand-written and generated files).
- [ ] **Step 2: Format**

Run: `nix develop .#dev --command fourmolu --mode inplace $(git ls-files '*.hs')`
- [ ] **Step 3: Verify goldens still match** (`cabal test`), then commit.

```bash
git add fourmolu.yaml src test app && git commit -m "style: fourmolu config and format tree"
```

### Task 7.2: GitHub Actions (hermetic only)

**Files:**
- Create: `.github/actions/setup/action.yml`
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write `.github/actions/setup/action.yml`** — composite action: install Nix (`DeterminateSystems/nix-installer-action@main`) and cache `dist-newstyle` (`actions/cache@v6`) keyed on `hashFiles('flake.lock','flake.nix','**/*.cabal','cabal.project','src/**/*.hs','test/**/*.hs','app/**/*.hs')`.

```yaml
name: Setup
description: Install Nix and restore the cabal build cache.
runs:
  using: composite
  steps:
    - name: Install Nix
      uses: DeterminateSystems/nix-installer-action@main
    - name: Cache build
      uses: actions/cache@v6
      with:
        path: dist-newstyle
        key: dist-${{ runner.os }}-${{ hashFiles('flake.lock','flake.nix','**/*.cabal','cabal.project','src/**/*.hs','test/**/*.hs','app/**/*.hs') }}
```

- [ ] **Step 2: Write `.github/workflows/ci.yml`** — jobs `build` (`nix develop .#dev --command cabal build all`), `test` (needs build; `cabal test --test-show-details=direct`), `format` (needs build; `fourmolu --mode check $(git ls-files '*.hs')`). No live/e2e job.

```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request:
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v5
      - uses: ./.github/actions/setup
      - run: nix develop .#dev --command cabal build all
  test:
    needs: build
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v5
      - uses: ./.github/actions/setup
      - run: nix develop .#dev --command cabal test --test-show-details=direct
  format:
    needs: build
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v5
      - uses: ./.github/actions/setup
      - run: nix develop .#dev --command bash -c "fourmolu --mode check \$(git ls-files '*.hs')"
```

- [ ] **Step 3: Commit**

```bash
git add .github && git commit -m "ci: hermetic build/test/format workflow"
```

### Task 7.3: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`** with the hs-inngest-style sections: status/surface coverage; build & test (`nix develop .#dev --command cabal build/test`); the codegen CLI usage (`spacetime describe --json <db> | cabal run hs-spacetime-codegen -- out.hs [--skip]`); the live suite (how to run it in `.#live` with `SPACETIMEDB_INTEGRATION=1`, note the connection-refused noise in hermetic reconnect tests, and the rejected-token vs server-down distinction); a quick API sketch (builder → subscribe_query → call_reducer); a layout table mapping modules to responsibilities; and a note that CI is hermetic-only by design.

- [ ] **Step 2: Commit**

```bash
git add README.md && git commit -m "docs: README"
```

**Phase 7 done when:** CI is green on a push, `fourmolu --check` passes tree-wide, and the README documents build, codegen, and the live suite.

---

## Final verification

- [ ] `nix develop .#dev --command cabal test --test-show-details=direct` — all hermetic suites green.
- [ ] `nix develop .#dev --command bash -c "fourmolu --mode check \$(git ls-files '*.hs')"` — clean.
- [ ] `SPACETIMEDB_INTEGRATION=1 nix develop .#live --command cabal test --test-show-details=direct` — all 8 live checks pass.
- [ ] Regenerate goldens (`scripts/live-harness.sh regenerate …`) and confirm the committed file is byte-identical.
