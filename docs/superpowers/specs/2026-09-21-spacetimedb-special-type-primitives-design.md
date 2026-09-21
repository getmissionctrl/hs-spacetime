# SpacetimeDB Special-Type Primitives — Design

**Status:** approved design, pre-plan
**Date:** 2026-09-21
**Scope:** a standalone, mergeable batch that adds `SpacetimeType` support for SpacetimeDB's special scalar types (`Identity`, `Timestamp`, `ConnectionId`) and `Maybe`/option, byte-matched against a Rust oracle. This unblocks realistic modules (including the deferred quickstart-chat example) but ships and merges to `main` on its own.

## Goal

An author can put `Identity`, `Timestamp`, `ConnectionId`, and `Maybe a` fields in an HKD table row (or a reducer-argument record) and have `deriveModule` emit **byte-identical schema** to what the Rust module toolchain produces for the same types, with correct BSATN row/argument codecs. Nothing else about the authoring surface changes.

Concretely, after this batch:

```haskell
data User f = User
  { identity :: Column f Identity '[ 'Pk]
  , name     :: Column f (Maybe Text) '[]
  , online   :: Column f Bool '[]
  }
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (User 'Value)   -- compiles; schema matches Rust
```

## Non-goals

- The quickstart-chat module, live test, TS generation, and Next.js UI — deferred to a separate spec.
- List/array (`[a]`) column support — explicitly out of this batch.
- Any user-defined *nested* product/sum hoisting beyond the special types + option named here.
- Client-side codegen changes (the `hs-spacetime-codegen` option handling already exists; untouched here).

## The oracle (discovery gate)

The whole batch hinges on one unknown: **does SpacetimeDB represent these special types *inline* in a row product, or as *typespace references* (`AlgebraicTypeRef`) into named typespace entries?** We do not guess — we observe.

**Task A1 builds a minimal Rust probe fixture** under `test/fixtures/probe/` (a standalone Cargo project — deliberately *not* under the deferred `examples/quickstart-chat/` tree, so this batch is self-contained) — one table whose row exercises all four types:

```rust
#[table(name = probe, public)]
struct Probe {
    #[primary_key] id: Identity,
    ts: Timestamp,
    conn: ConnectionId,
    maybe_name: Option<String>,
}
```

Build it with the Rust wasm toolchain already in `.#live`/`.#wasm`, capture its `RawModuleDefV10` schema bytes via the existing describe-host pattern (`phase0/host` / `phase1/scripts/capture-golden.sh`) into `phase2/golden/probe.schema.bsatn` (alongside the existing `widget`/`event` goldens). This golden is the source of truth for every subsequent task and **resolves the inline-vs-ref question before any Haskell instance is written.**

## Expected SATS forms (golden-confirmed)

At the **schema** level, the special types are single-field products with reserved field-name markers; option is a two-variant sum:

| Type | SATS (expected) |
|---|---|
| `Identity` | product `[("__identity__", U256)]` |
| `Timestamp` | product `[("__timestamp_micros_since_unix_epoch__", I64)]` |
| `ConnectionId` | product `[("__connection_id__", U128)]` |
| `Maybe a` | sum `[("some", ⟨a⟩), ("none", product[])]` |

At the **value/BSATN** level the encodings are flat (a single-field product is just its field's bytes; a sum is a tag byte then the variant payload), and reuse the existing `bsatn` codecs (`encodeIdentity`/`decodeIdentity`, `encodeTimestamp`/`decodeTimestamp`, the `ConnectionId` u128 codec, `encodeU8` tag + payload for option). No new byte-level machinery is expected; the golden confirms the exact bytes.

## Architecture — two branches, decided by A1

`SpacetimeType`'s `algebraicType :: AlgType` is a pure, context-free value, so it cannot itself mint a typespace ref (refs need a slot assigned during module assembly). Which branch we take depends on the golden:

**Branch INLINE** (if the golden inlines the special types into the row product):
- Add four `SpacetimeType` instances whose `algebraicType` returns the inline product/sum above, and whose `encodeVal`/`decodeVal` reuse the existing `bsatn` codecs.
- `deriveModule` is unchanged. Done.

**Branch REF** (if the golden hoists special types into named typespace entries referenced by the row) — the expected case:
- `SpacetimeType` gains a way to report a type's *named* SATS definition (name + body) so `deriveModule` can register it. Minimal shape: an optional class method (default `Nothing`) returning a `NamedType` descriptor; the four special types override it, everything else keeps the default.
- `deriveModule`'s schema assembly grows a **typespace-registration pass**: collect the distinct named types used across all rows (and reducer args), append them to `typespace` + `types` with stable refs, and rewrite row/arg field types that are named to `TRef <slot>`. Table `productTypeRef` values shift by the number of registered named types; column indices are unaffected (they index within a row, not the typespace).
- This pass is the one non-trivial change; it is additive and covered by the golden byte-match plus the existing event/widget/person goldens (which must still pass unchanged, since they use no special types).

The plan will commit to one branch after A1 and will not carry both.

## Testing strategy

All hermetic (runs in `.#dev`, no server), matching the repo's existing rigor:

1. **Per-type unit tests** (`SpacetimeTypeSpec`): each instance's `algebraicType` equals the expected form; each value round-trips through `encodeVal`/`decodeVal` (e.g. an `Identity`, a `Timestamp`, a `ConnectionId`, `Just "x"`, `Nothing`).
2. **Schema byte-match** (`ProbeSchemaSpec` or an addition to an existing schema spec): a Haskell row mirroring the Rust `Probe` table, run through `deriveModule`, asserted equal to `golden/probe.schema.bsatn`.
3. **Regression**: the existing `event`/`widget`/`person` goldens must still byte-match (guards the typespace-registration pass against disturbing special-type-free modules).

The Rust reference builds only in `.#live`/`.#wasm`; the captured golden is committed, so the hermetic suite needs no toolchain — same arrangement as the existing goldens.

## Files

**Create:**
- `test/fixtures/probe/` — standalone Rust probe fixture (Cargo project) + build/capture wiring.
- `phase2/golden/probe.schema.bsatn` — captured oracle golden.
- A probe byte-match test (a small new spec, or an addition to the existing `SchemaSpec`).

**Modify:**
- `server/src/SpacetimeDB/Server/SpacetimeType.hs` — four instances (+ the `NamedType` reporting method in Branch REF).
- `server/src/SpacetimeDB/Server/Derive.hs` — Branch REF only: typespace-registration pass.
- `test/SpacetimeDB/Server/SpacetimeTypeSpec.hs` — per-type unit tests.
- `hs-spacetime.cabal`, `test/Spec.hs` — register any new spec module.

## Risks / open questions

- **Inline vs ref (resolved by A1).** The plan branches after the golden; REF is expected and budgeted.
- **Option representation.** `Option<T>` may be inlined as a sum even if the scalar special types are ref'd; the golden shows this per-field. The `Maybe` instance is written to match whichever the golden dictates.
- **Typespace ref ordering.** If Branch REF, the order in which named types are registered must match the Rust emitter's order for a byte-match; the golden pins it (registration in first-use order across the row walk is the first hypothesis, corrected against the golden if needed).
- **`deriveModule` blast radius.** Branch REF touches shared schema assembly; the existing three goldens are the regression net and must stay green.

## Merge

Ships as its own set of TDD commits and merges to `main` before the quickstart-chat example work resumes. The example spec will then be written against these primitives.
