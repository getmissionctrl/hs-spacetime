# SpacetimeDB Special-Type Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `SpacetimeType` instances for SpacetimeDB's special scalar types (`Identity`, `Timestamp`, `ConnectionId`) and `Maybe a` (option), so authors can use them in HKD table rows and reducer arguments, with schema byte-identical to the Rust toolchain.

**Architecture:** The discovery gate is already resolved (see Design doc + the notes below): SpacetimeDB represents these special types **inline** — each special scalar is a single-field product with a reserved marker field name (`__identity__`, `__timestamp_micros_since_unix_epoch__`, `__connection_id__`), and `Option<T>` is a two-variant sum (`some`/`none`). Because they are inline, **no change to `deriveModule` or the Generic machinery is needed** — four `SpacetimeType` instances whose `algebraicType` returns those inline shapes, reusing the existing `bsatn` value codecs, is the entire feature. A Rust "probe" module is the oracle: its raw `__describe_module__` bytes are captured as a golden, and a mirror Haskell module's `deriveModule` output is asserted byte-identical.

**Tech Stack:** GHC 9.10.3 (native, nix devshell `.#dev`), hspec, fourmolu; Rust + `spacetime` CLI + the `phase0/host` describe binary (nix devshell `.#live`) for the oracle only.

**Conventions:**
- Native commands run in `.#dev`, e.g. `nix develop .#dev --command cabal test`. The Rust oracle capture (Task 1 only) runs in `.#live`.
- Field convention: `DuplicateRecordFields` + `NoFieldSelectors` + `OverloadedRecordDot`, `deriving stock (…, Generic)`. Never prefix field names.
- Format touched Haskell files with `nix develop .#dev --command fourmolu -i <files>` before each commit.
- Commit trailers (append to every commit message):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016WZ3cT8fjfvnPjMTPJFi54
  ```
- The TDD loop (write test → see it fail → implement → see it pass) is the source of truth. If a code block here doesn't compile verbatim, fix minimally to make the stated test pass without changing the test's intent.

**Resolved facts from discovery (do not re-litigate):**
- The special types are **inline** (not typespace refs); the typespace has exactly one entry per table (the row product), unchanged from today.
- `algebraicType` shapes (confirmed against the Rust probe's `spacetime describe --json`):
  - `Identity` → `TProduct [Field (Just "__identity__") TU256]`
  - `Timestamp` → `TProduct [Field (Just "__timestamp_micros_since_unix_epoch__") TI64]`
  - `ConnectionId` → `TProduct [Field (Just "__connection_id__") TU128]`
  - `Maybe a` → `TSum [Field (Just "some") (algebraicType @a), Field (Just "none") (TProduct [])]`
- Value BSATN reuses existing `bsatn` codecs: `encodeIdentity`/`decodeIdentity` (u256), `encodeTimestamp`/`decodeTimestamp` (i64), `encodeConnectionId`/`decodeConnectionId` (u128), and `encodeOptionalOf`/`optional` (tag 0 = some, tag 1 = none).
- The **golden must be captured from the raw `__describe_module__` output** via `phase0/host --describe` (like the existing `widget`/`event` goldens). `spacetime describe --json` on a *published* module differs — the server adds constraint names (e.g. `probe_id_key`) that the module itself does not emit; the raw output leaves the unique constraint unnamed, which is what `deriveModule` produces.

---

## File Structure

**Create:**
- `test/fixtures/probe/Cargo.toml`, `test/fixtures/probe/src/lib.rs` — the Rust oracle module (one table exercising all four types + an `init` reducer). Standalone; not under the deferred `examples/quickstart-chat/` tree.
- `test/fixtures/probe/capture-golden.sh` — reproducible capture (build → `phase0/host --describe` → `phase2/golden/probe.schema.bsatn`).
- `phase2/golden/probe.schema.bsatn` — the captured oracle golden (committed binary).

**Modify:**
- `server/src/SpacetimeDB/Server/SpacetimeType.hs` — add the four instances + their imports.
- `test/SpacetimeDB/Server/SpacetimeTypeSpec.hs` — per-type `algebraicType` + BSATN round-trip tests.
- `test/SpacetimeDB/Server/DeriveSpec.hs` — the probe module byte-match (mirror Haskell module vs golden).

No `deriveModule`, `HKD`, or cabal/`Spec.hs` module-registration changes are required (tests reuse existing spec modules).

---

## Task 1: Rust probe oracle + captured golden

**Files:**
- Create: `test/fixtures/probe/Cargo.toml`
- Create: `test/fixtures/probe/src/lib.rs`
- Create: `test/fixtures/probe/capture-golden.sh`
- Create: `phase2/golden/probe.schema.bsatn` (generated)

- [ ] **Step 1: Create the Rust probe crate**

`test/fixtures/probe/Cargo.toml`:

```toml
[package]
name = "hs-spacetime-probe"
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

`test/fixtures/probe/src/lib.rs` (single-word field names so the column names are identical in Rust and Haskell — the derivation uses field names verbatim):

```rust
use spacetimedb::{reducer, table, ConnectionId, Identity, ReducerContext, Timestamp};

#[table(accessor = probe, public)]
pub struct Probe {
    #[primary_key]
    pub id: Identity,
    pub ts: Timestamp,
    pub conn: ConnectionId,
    pub note: Option<String>,
}

#[reducer(init)]
pub fn init(_ctx: &ReducerContext) {}
```

- [ ] **Step 2: Create the capture script**

`test/fixtures/probe/capture-golden.sh`:

```bash
#!/usr/bin/env bash
# Capture the raw __describe_module__ schema of the probe fixture into the golden.
# Run inside `.#live` (provides `spacetime` + a Rust toolchain). Mirrors
# phase1/scripts/capture-golden.sh but targets the probe fixture.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
export RUSTUP_HOME="${HS_ST_RUSTUP_HOME:-/tmp/hs-st-rust/rustup}"
export CARGO_HOME="${HS_ST_CARGO_HOME:-/tmp/hs-st-rust/cargo}"
rustup default stable >/dev/null 2>&1 || true
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cd "$root/test/fixtures/probe"
cargo build --release --target wasm32-unknown-unknown
wasm="target/wasm32-unknown-unknown/release/hs_spacetime_probe.wasm"
cd "$root/phase0/host"
cargo run --quiet --bin phase0-host -- --describe "$root/test/fixtures/probe/$wasm" \
  > "$root/phase2/golden/probe.schema.bsatn"
echo "wrote phase2/golden/probe.schema.bsatn ($(wc -c < "$root/phase2/golden/probe.schema.bsatn") bytes)"
```

Make it executable: `chmod +x test/fixtures/probe/capture-golden.sh`.

- [ ] **Step 3: Capture the golden**

Run: `nix develop .#live --command bash test/fixtures/probe/capture-golden.sh`
Expected: `wrote phase2/golden/probe.schema.bsatn (<N> bytes)` with N ≈ 335.

- [ ] **Step 4: Sanity-check the golden's structure**

Run: `strings phase2/golden/probe.schema.bsatn`
Expected to contain: `__identity__`, `__timestamp_micros_since_unix_epoch__`, `__connection_id__`, `some`, `none`, `Probe`, `probe`, `probe_id_idx_btree`.
Expected to **NOT** contain: `probe_id_key` (a server-only post-publish name; its absence confirms this is the raw module describe, which `deriveModule` matches).

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/probe/Cargo.toml test/fixtures/probe/src/lib.rs \
        test/fixtures/probe/capture-golden.sh phase2/golden/probe.schema.bsatn
git commit -m "test(primitives): Rust probe oracle + captured schema golden

<trailers>"
```

---

## Task 2: `SpacetimeType Identity`

**Files:**
- Modify: `server/src/SpacetimeDB/Server/SpacetimeType.hs`
- Test: `test/SpacetimeDB/Server/SpacetimeTypeSpec.hs`

- [ ] **Step 1: Write the failing test**

Add to `test/SpacetimeDB/Server/SpacetimeTypeSpec.hs`. First ensure these imports are present (add any that are missing):

```haskell
import SpacetimeDB.BSATN.Types (Identity, identityFromInteger, ConnectionId, connectionIdFromInteger, Timestamp (..))
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Server.Schema (AlgType (..), Field (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
```

Add these examples to the spec (inside the existing top-level `describe`, or a new `describe "special types"`):

```haskell
  it "Identity has the __identity__ product schema" $
    algebraicType @Identity `shouldBe` TProduct [Field (Just "__identity__") TU256]

  it "Identity round-trips through its BSATN codec" $ do
    let x = identityFromInteger 123456789
    runExact (decodeVal @Identity) (runEncoder encodeVal x) `shouldBe` Right x
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `No instance for (SpacetimeType Identity)`.

- [ ] **Step 3: Implement the instance**

In `server/src/SpacetimeDB/Server/SpacetimeType.hs`, add the import:

```haskell
import SpacetimeDB.BSATN.Types
  ( ConnectionId
  , Identity
  , Timestamp
  , decodeConnectionId
  , decodeIdentity
  , decodeTimestamp
  , encodeConnectionId
  , encodeIdentity
  , encodeTimestamp
  )
```

and the instance (place it after the primitive instances, before the Generic machinery):

```haskell
instance SpacetimeType Identity where
  algebraicType = TProduct [Field (Just "__identity__") TU256]
  encodeVal = encodeIdentity
  decodeVal = decodeIdentity
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: PASS — both Identity examples green; suite still 0 failures.

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/SpacetimeType.hs test/SpacetimeDB/Server/SpacetimeTypeSpec.hs
git add server/src/SpacetimeDB/Server/SpacetimeType.hs test/SpacetimeDB/Server/SpacetimeTypeSpec.hs
git commit -m "feat(primitives): SpacetimeType Identity (inline __identity__ product)

<trailers>"
```

---

## Task 3: `SpacetimeType Timestamp`

**Files:**
- Modify: `server/src/SpacetimeDB/Server/SpacetimeType.hs`
- Test: `test/SpacetimeDB/Server/SpacetimeTypeSpec.hs`

- [ ] **Step 1: Write the failing test**

Add to `SpacetimeTypeSpec.hs` (`Timestamp (..)` is already imported from Task 2):

```haskell
  it "Timestamp has the __timestamp_micros_since_unix_epoch__ product schema" $
    algebraicType @Timestamp
      `shouldBe` TProduct [Field (Just "__timestamp_micros_since_unix_epoch__") TI64]

  it "Timestamp round-trips through its BSATN codec" $ do
    let x = Timestamp 1700000000000000
    runExact (decodeVal @Timestamp) (runEncoder encodeVal x) `shouldBe` Right x
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `No instance for (SpacetimeType Timestamp)`.

- [ ] **Step 3: Implement the instance**

Add to `SpacetimeType.hs` (imports already added in Task 2):

```haskell
instance SpacetimeType Timestamp where
  algebraicType = TProduct [Field (Just "__timestamp_micros_since_unix_epoch__") TI64]
  encodeVal = encodeTimestamp
  decodeVal = decodeTimestamp
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/SpacetimeType.hs test/SpacetimeDB/Server/SpacetimeTypeSpec.hs
git add server/src/SpacetimeDB/Server/SpacetimeType.hs test/SpacetimeDB/Server/SpacetimeTypeSpec.hs
git commit -m "feat(primitives): SpacetimeType Timestamp (inline micros product)

<trailers>"
```

---

## Task 4: `SpacetimeType ConnectionId`

**Files:**
- Modify: `server/src/SpacetimeDB/Server/SpacetimeType.hs`
- Test: `test/SpacetimeDB/Server/SpacetimeTypeSpec.hs`

- [ ] **Step 1: Write the failing test**

Add to `SpacetimeTypeSpec.hs` (`ConnectionId`, `connectionIdFromInteger` imported in Task 2):

```haskell
  it "ConnectionId has the __connection_id__ product schema" $
    algebraicType @ConnectionId `shouldBe` TProduct [Field (Just "__connection_id__") TU128]

  it "ConnectionId round-trips through its BSATN codec" $ do
    let x = connectionIdFromInteger 987654321
    runExact (decodeVal @ConnectionId) (runEncoder encodeVal x) `shouldBe` Right x
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `No instance for (SpacetimeType ConnectionId)`.

- [ ] **Step 3: Implement the instance**

Add to `SpacetimeType.hs`:

```haskell
instance SpacetimeType ConnectionId where
  algebraicType = TProduct [Field (Just "__connection_id__") TU128]
  encodeVal = encodeConnectionId
  decodeVal = decodeConnectionId
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/SpacetimeType.hs test/SpacetimeDB/Server/SpacetimeTypeSpec.hs
git add server/src/SpacetimeDB/Server/SpacetimeType.hs test/SpacetimeDB/Server/SpacetimeTypeSpec.hs
git commit -m "feat(primitives): SpacetimeType ConnectionId (inline __connection_id__ product)

<trailers>"
```

---

## Task 5: `SpacetimeType (Maybe a)` (option)

**Files:**
- Modify: `server/src/SpacetimeDB/Server/SpacetimeType.hs`
- Test: `test/SpacetimeDB/Server/SpacetimeTypeSpec.hs`

- [ ] **Step 1: Write the failing test**

Add to `SpacetimeTypeSpec.hs` (uses `Data.Text (Text)` — add the import if not present):

```haskell
  it "Maybe has the some/none option sum schema" $
    algebraicType @(Maybe Text)
      `shouldBe` TSum [Field (Just "some") TString, Field (Just "none") (TProduct [])]

  it "Maybe round-trips Just and Nothing through its BSATN codec" $ do
    runExact (decodeVal @(Maybe Text)) (runEncoder encodeVal (Just "hi")) `shouldBe` Right (Just "hi")
    runExact (decodeVal @(Maybe Text)) (runEncoder encodeVal (Nothing :: Maybe Text)) `shouldBe` Right Nothing
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `No instance for (SpacetimeType (Maybe a))`.

- [ ] **Step 3: Implement the instance**

Add to `SpacetimeType.hs`. The value codecs `encodeOptionalOf` and `optional` come from the already-open imports of `SpacetimeDB.BSATN.Encoder` / `SpacetimeDB.BSATN.Decoder`; `TSum` comes from the already-imported `AlgType (..)`:

```haskell
instance (SpacetimeType a) => SpacetimeType (Maybe a) where
  algebraicType = TSum [Field (Just "some") (algebraicType @a), Field (Just "none") (TProduct [])]
  encodeVal = encodeOptionalOf encodeVal
  decodeVal = optional decodeVal
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/SpacetimeType.hs test/SpacetimeDB/Server/SpacetimeTypeSpec.hs
git add server/src/SpacetimeDB/Server/SpacetimeType.hs test/SpacetimeDB/Server/SpacetimeTypeSpec.hs
git commit -m "feat(primitives): SpacetimeType (Maybe a) option (some/none sum)

<trailers>"
```

---

## Task 6: Probe module schema byte-match (integration proof)

**Files:**
- Modify: `test/SpacetimeDB/Server/DeriveSpec.hs`

This proves the four instances compose through `deriveModule` to byte-identical schema — with **zero** `deriveModule` changes.

- [ ] **Step 1: Write the failing test**

In `test/SpacetimeDB/Server/DeriveSpec.hs`, add imports (some may already be present — add only the missing ones):

```haskell
import SpacetimeDB.BSATN.Types (ConnectionId, Identity, Timestamp)
```

Add the probe fixture (distinct `Probe*` names to avoid collisions with the existing `App`/`Widget` fixtures in this file):

```haskell
data Probe f = Probe
  { id :: Column f Identity '[ 'Pk]
  , ts :: Column f Timestamp '[]
  , conn :: Column f ConnectionId '[]
  , note :: Column f (Maybe Text) '[]
  }
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (Probe 'Value)

data ProbeApp = ProbeApp
  { probe :: Table Probe
  , init :: LifecycleHook 'Init
  }
  deriving stock (Generic)

probeApp :: ProbeApp
probeApp = deriveApp

data ProbeHandlers = ProbeHandlers {init :: () -> ReducerM ()}
  deriving stock (Generic)

probeModule :: ModuleDef
probeModule = deriveModule probeApp ProbeHandlers {init = \() -> pure ()}
```

Add the byte-match example (inside the `deriveModule` `describe` block):

```haskell
    it "probe App (Identity/Timestamp/ConnectionId/Maybe) matches the Rust golden" $ do
      golden <- BS.readFile "phase2/golden/probe.schema.bsatn"
      describeBytes probeModule `shouldBe` golden
```

- [ ] **Step 2: Run to verify it fails, then passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -30`
Expected: the new example PASS (the instances are already implemented from Tasks 2–5, so this compiles and should byte-match immediately). The existing `widget`/`event`/`person` goldens and all other examples must remain PASS.

If the bytes differ, diff the structure against `phase2/golden/probe.schema.bsatn` (decode with `strings` and compare field order / marker names); the most likely cause would be a field-name mismatch between `Probe` here and the Rust `Probe` in Task 1 (they must be identical: `id`, `ts`, `conn`, `note`).

- [ ] **Step 3: Format and commit**

```bash
nix develop .#dev --command fourmolu -i test/SpacetimeDB/Server/DeriveSpec.hs
git add test/SpacetimeDB/Server/DeriveSpec.hs
git commit -m "test(primitives): probe App derives schema byte-identical to Rust golden

<trailers>"
```

---

## Task 7: Full green + formatting sweep

**Files:** none (verification)

- [ ] **Step 1: Run the whole native suite**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -30`
Expected: all examples pass, 0 failures. Example count is the pre-change count + 9 (2 Identity, 2 Timestamp, 2 ConnectionId, 2 Maybe, 1 probe byte-match).

- [ ] **Step 2: Format sweep**

Run: `nix develop .#dev --command fourmolu -i $(git diff --name-only main -- '*.hs')`
Then `nix develop .#dev --command cabal test 2>&1 | tail -5` to confirm still green.

- [ ] **Step 3: Commit any formatting**

```bash
git add -A
git commit -m "style(primitives): fourmolu sweep

<trailers>"   # skip if nothing changed
```

- [ ] **Step 4: Finish the branch**

Use superpowers:finishing-a-development-branch to merge `special-type-primitives` to `main` and push (the user asked for this batch merged to main before the example work resumes).

---

## Self-Review Notes (author)

- **Spec coverage:** oracle + golden (Task 1), the four `SpacetimeType` instances with round-trips (Tasks 2–5), the byte-match integration proof (Task 6), regression net via the existing goldens (Task 6 Step 2 + Task 7). Non-goals (list/array columns, nested user-type hoisting, the quickstart-chat app) are absent by design.
- **Branch decided:** discovery resolved **INLINE**, so the design's "Branch REF" (typespace-registration pass in `deriveModule`) is **not** implemented — no `deriveModule` change appears in any task. If, contrary to the captured golden, Task 6 shows the row referencing special types by `TRef`, stop and revisit — that would mean the golden was captured wrong (e.g. via `spacetime describe --json` instead of the raw `phase0/host --describe`).
- **Type consistency:** the Rust `Probe` fields (`id`, `ts`, `conn`, `note`) and the Haskell `Probe` fields are identical, so column names match; `algebraicType` shapes in the tests match the instances exactly; value codecs reuse `encode*`/`decode*` and `encodeOptionalOf`/`optional` verbatim.
- **No placeholders:** every step has literal code or an exact command with expected output.
