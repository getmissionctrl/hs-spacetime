# Haskell SpacetimeDB Client — Design

**Date:** 2026-09-10
**Status:** Approved, pending implementation plan

## Overview

A full-featured **SpacetimeDB v2 client library for Haskell**, speaking the
`v2.bsatn.spacetimedb` WebSocket protocol, plus a **bindings generator** that
reads the V10 module schema. Built bottom-up in four layers — BSATN codec →
v2 protocol → client → codegen — each tested before the next is started.
Ships a hermetic test suite (what CI runs) and an opt-in live suite that
drives the client against a real server.

**Client-only.** The single piece of server code is a tiny Rust fixture module
(one table, one reducer, one seeded row) that the live suite publishes so
there is something to talk to.

Derived from the `spacetimedb-client` skill (itself distilled from a Gleam
implementation) and mirroring the project conventions of the sibling
`hs-inngest` repo. Divergences from the skill are recorded explicitly in
§9 — the most important being that we do **not** reproduce the skill's
owner/socket actor split.

## Scope

**In scope:**

- A **BSATN codec**: every primitive, strings, bytes, arrays, options,
  products, sums, plus decoder/encoder combinators so generated code is
  compositional.
- The **v2 protocol**: handshake, per-frame compression byte, all five client
  messages and all eight server messages, row-list splitting.
- A **client**: builder API, subscriptions (declared up front and added/dropped
  at runtime), typed per-table row dispatch, reducer/procedure/one-off calls,
  reconnect with exponential backoff that replays subscriptions under the same
  ids, server-issued token that survives reconnects and can be persisted.
- A **bindings generator** reading `RawModuleDefV10` JSON: row records,
  decoders, encoders, enums, nested named products, one typed call wrapper per
  client-callable reducer/procedure.
- **Tests**: hermetic (codec properties, protocol hex fixtures, pure-client
  transitions, codegen goldens) and a live suite.

**Out of scope:** writing server modules (except the tiny live fixture); a
primary-key-keyed client row cache with synchronous reads and derived
`Updated(old,new)` per-row callbacks (plan the primary key into the schema
model now, but don't build the cache yet); the `SendDroppedRows` unsubscribe
flag.

## Package layout

Mirrors `hs-inngest`: package `hs-spacetime`, `cabal-version: 3.0`,
`Haskell2010`, a common `warnings` stanza with `-Wall`, built via
`callCabal2nix`. Module namespace `SpacetimeDB`, flat under `src/`.

```
src/SpacetimeDB.hs                      -- root re-export (public API surface)
src/SpacetimeDB/BSATN/Decoder.hs        -- Decoder a = BS -> Either DecodeError (a, BS); combinators; runExact; decodeRows
src/SpacetimeDB/BSATN/Encoder.hs        -- Encoder a = a -> Builder; concatE / contramap / encodeSum
src/SpacetimeDB/BSATN/Types.hs          -- Identity, ConnectionId, Timestamp, TimeDuration, Uuid (opaque)
src/SpacetimeDB/Protocol/Frame.hs       -- decodeFrame: compression byte (0/1/2), inflate, tag dispatch
src/SpacetimeDB/Protocol/Messages.hs    -- ServerMessage (0..7 + Unhandled), ClientMessage (0..4), nested types
src/SpacetimeDB/Protocol/RowList.hs     -- BsatnRowList splitting (FixedSize / RowOffsets) -> [ByteString]
src/SpacetimeDB/Client.hs               -- builder, handle, public API
src/SpacetimeDB/Client/State.hs         -- PURE ClientState + transitions
src/SpacetimeDB/Client/Connection.hs    -- IO shell: socket, reader, writer, reconnect loop
src/SpacetimeDB/Client/Types.hs         -- Event, ClientError, reply taxonomies
src/SpacetimeDB/Codegen.hs              -- schema JSON -> source text (pure)
src/SpacetimeDB/Codegen/Schema.hs       -- V10 model, resolution, fixpoint
```

**Executables:** `hs-spacetime-codegen` (generator CLI: stdin → stdout/file,
`--skip`). No example executable in v1 (the live suite is the end-to-end
demonstration); add one later if useful.

**Test suite** `hs-spacetime-test`: manual `Spec.hs` (no `hspec-discover`),
one `*Spec` module per source module. Live checks are gated behind
`SPACETIMEDB_INTEGRATION=1` and only added to the runner when the variable is
set, so the default `cabal test` stays hermetic.

## Layer 1 — BSATN codec

- `Decoder a = ByteString -> Either DecodeError (a, ByteString)`, threading the
  remainder so decoders compose without offset tracking. Combinators:
  `success`, monadic bind (`then_`), `map`, `sumD` (read `u8` tag → payload
  decoder or `UnknownVariant`).
- `DecodeError = UnexpectedEnd | InvalidBool Word8 | InvalidUtf8 |
  UnknownVariant Word8 | Custom Text`.
- Run helpers: `runExact` (require every byte consumed) and `decodeRows`
  (`runExact` per split row, reporting the failing index).
- `Encoder a = a -> Builder`; combinators `concatE`, `contramap`, `encodeSum`,
  plus lifted `list`/`optional` forms. Direct and point-free forms both kept.
- Wire rules: all int widths little-endian, two's complement signed;
  `Word128/Word256/Int256` from **wide-word**; `u32`-length-prefixed
  string/bytes/array; products = bare field concatenation (no framing); sums =
  `u8` tag then payload; **Option `some` = tag 0, `none` = tag 1**; Result
  `ok` = 0, `err` = 1; unit `()` = zero bytes (decoder must succeed on empty
  input).
- Special single-field `__x__` products map to opaque types: `Identity`
  (u256, 32 LE, 64 lowercase hex), `ConnectionId` (u128, 16 LE),
  `Timestamp`/`TimeDuration` (i64, 8 LE, **microseconds**), `Uuid` (u128,
  transparent wrapper). Minimal accessors only (`fromInt`/`toInt`/`toHex`/
  `compare`); calendar formatting is the user's job.

**Done when:** `runExact (encode x) decode == Right x` under a property test
with boundary-biased generators (0, 1, −1, 2^(n−1), 2^n−1, −2^(n−1) per width),
wide integers built from 30-bit chunks so the high bytes are exercised.

## Layer 2 — v2 protocol

- Handshake: `GET <base>/v1/database/<db>/subscribe?compression=…[&confirmed=…]`,
  `Sec-WebSocket-Protocol: v2.bsatn.spacetimedb`, optional
  `Authorization: Bearer`. Route + params assembled in one place. `ws(s)://`
  rewritten to `http(s)://`. `compression` spelled exactly `None|Brotli|Gzip`;
  `confirmed` omitted unless the user set it; `light`/`connection_id` not sent.
- `decodeFrame :: ByteString -> Either FrameError ServerMessage`: strip the
  leading compression tag (0 none / 1 brotli via **brotli** / 2 gzip via
  **zlib**), inflate, `runExact` a `ServerMessage`. All three tags supported
  regardless of what was requested (small frames arrive uncompressed).
  `FrameError = EmptyFrame | UnsupportedCompression Word8 | BrotliFailed |
  GzipFailed | Bsatn DecodeError`.
- `ServerMessage` tags 0–7 (`InitialConnection`, `SubscribeApplied`,
  `UnsubscribeApplied`, `SubscriptionError`, `TransactionUpdate`,
  `OneOffQueryResult`, `ReducerResult`, `ProcedureResult`) plus
  `Unhandled Word8` for any higher tag (surfaced as an event, never fatal).
  Nested types modelled exactly: `QueryRows`, `SingleTableRows`,
  `QuerySetUpdate`, `TableUpdate`, `TableUpdateRows` (sum: PersistentTable /
  EventTable), `ReducerOutcome` (Ok / OkEmpty / Err / InternalError),
  `ProcedureStatus`. Traps honoured: `ReducerOk.transaction_update` is a
  one-field product; a unit-returning reducer comes back as `Ok` with a
  **zero-length `ret_value`** (not `OkEmpty`); `ProcedureResult`'s
  `request_id` is **last**; `SubscriptionError.request_id` is `Option`.
- Five `encode*` client-message functions (ids as parameters, `args` opaque
  `Bytes`; `CallReducer` writes `flags: u8` before the name; empty args =
  `00 00 00 00`).
- `BsatnRowList` split **in this layer** into `[ByteString]` per table
  (`FixedSize u16` / `RowOffsets [u64]`; a `0` hint means no rows), each row
  decoded upward with `runExact`.

**Done when:** captured frames decode and a hand-built `Subscribe` matches the
expected hex.

## Layer 3 — client

**Design decision (diverges from the skill):** a **single durable state value
plus a programmatic reconnect loop**, not the skill's owner/socket two-role
actor split. The skill's split is a BEAM idiom (a linked socket process that
must not cascade its death into a supervisor). SpacetimeDB itself imposes only
two facts: (1) some state must outlive any one connection — token,
subscription list with its `query_set_id`s, pending-call registry,
id/backoff counters; (2) everything else (the socket handle, the receive loop)
is per-connection and disposable, and the "socket's" routing table is *derived*
from the durable subscription list anyway. That needs one piece of durable
state and a connection lifecycle with cleanup — expressed in Haskell as an
**exception boundary**, not a process boundary.

- `SpacetimeDB.Client.State` holds a **pure** `ClientState` (token,
  subscriptions, pending calls, `nextQuerySetId`, `nextRequestId`, backoff)
  with pure transition functions — `allocateCall`, `applyReply`,
  `drainPending`, `registerSub`, `forgetSub`, `learnToken`, `applyServerMsg` —
  all testable with no socket. This is the skill's genuinely good idea, kept.
- `SpacetimeDB.Client.Connection` is the thin IO shell: a `TVar ClientState`
  plus an `outbound :: TQueue Frame` that serialises websocket sends (the
  `websockets` send path is not safe under concurrent callers). A connection
  is a `bracket`/`withAsync` scope racing a **reader** (recv → `decodeFrame` →
  dispatch) and a **writer** (drain `outbound`). When either thread throws
  (socket died) or `stop` fires, the scope tears down and control returns to a
  recursive **reconnect loop** which: `drainPending` (fails in-flight calls so
  no caller hangs), fires `Disconnected`, and — per policy — backs off and
  reconnects, replaying subscriptions under the existing ids with the
  server-issued token, resetting backoff on success.
- **Builder API** (immutable config, `start` does the first connect):
  `with_secure`, `with_base_uri`, `with_token`, `with_compression`,
  `with_confirmed_reads`, `with_reconnect`, `subscribe`, `subscribe_query`,
  `on_event`, `on_error`, `start`. `start` with `NoReconnect` fails
  synchronously on a failed first handshake; with reconnect it returns a handle
  and schedules retries (default 500 ms → 30 s, never giving up).
- **Handle API:** `stop`, `token` (blocking round-trip), `add_subscription` /
  `add_query_subscription` (blocking — id must exist before a handle is
  returned), `unsubscribe` (fire-and-forget), `subscription_id`,
  `call_reducer`, `call_procedure`, `one_off_query` (all callback-only, no
  blocking variant).
- **Threading contract (documented on every callback):** `on_event`,
  `on_change`, `on_result` run on the client's own threads; callbacks must be
  short; no blocking API may be called from inside a callback (it would wait on
  STM state the callback's own thread context needs).
- **Two dispatch paths, mutually exclusive per table:** a typed dispatcher
  (from `subscribe_query`, decoding with `decodeRows`, emitting
  `Initial | Changed(inserts,deletes)`, both halves decoded before either is
  emitted, a row-decode failure → `RowDecodeFailed(query,batch,index,reason)`
  event and carry on) or the raw `on_event` path (`InitialRows` / `Changed`,
  empty ops suppressed). Routing table derived from the live subscription list
  (newest wins), rebuilt whenever it changes.
- **Calls:** allocate `request_id`, store continuation, send frame; no socket →
  fail immediately ("not connected"); reply for a known id runs and forgets the
  continuation; unknown id → `UnmatchedReply` event; socket death / `stop`
  drains all pending. Reply taxonomies: `ReducerReply = Returned | ReturnedNothing
  | Failed | CallFailed`; `ProcedureReply = Returned | CallFailed`;
  `QueryReply = Returned | Rejected | CallFailed`. A `ReducerResult` carrying
  `Ok` dispatches its rows through table routing **before** delivering the
  reply; one-off rows bypass table routing entirely.
- **Subscription ids** client-chosen, per-connection, monotonic from 1, never
  reused even after being freed; replayed on reconnect under the same ids.
  Runtime add while disconnected is not an error (opens on next connect).

## Layer 4 — codegen

- Pure `RawModuleDefV10 JSON -> Either Error Text`, wrapped in a thin CLI
  reading stdin. `spacetime describe` prints an "UNSTABLE" warning to stderr —
  keep stdout/stderr apart.
- Parse the tagged sections (Typespace, Types, Tables, Reducers, Procedures,
  LifeCycleReducers, ExplicitNames), build the small schema model
  (`Typ = Ref | Array | Product | Sum | Prim`; Table/Reducer/Procedure records;
  `wire_names`, `declared`, computed `named`/`dropped`). `resolve` follows refs;
  dangling ref is an error.
- **Shape recognition** in order: Ref→named, Ref→dropped (error "depends on X"),
  primitive, `Array`, unit product, special product, transparent wrapper,
  `Option` (inline), otherwise-anonymous product/sum (error).
- **Emit** (tables by name, then declared types in schema order, then callables
  by name; each block independent): table/product records + decoders +
  encoders; sums as tagged unions with `sumD` decoders; one typed wrapper per
  **ClientCallable** reducer (ok+err decoders) and procedure (single return
  decoder). Drop `Private` callables silently. Wire names from
  `ExplicitNames.canonical_name`; function names from source name.
- Unsupported types are **fatal by default** (one line per offender + hint);
  `--skip` generates the rest and records `//// Skipped <name>: <reason>` in
  the header. Fixpoint: register all candidates as `named`, try each, drop
  failures, repeat until stable.
- **Output is deterministic and fourmolu-clean**; goldens compared
  byte-for-byte. Golden stability does not *depend* on invoking a formatter —
  we choose a layout fourmolu is idempotent on, and CI runs `fourmolu --check`
  as a guard.

## Testing

**Hermetic (CI-run):**

- Codec: round-trip properties per width (boundary-biased) + error-path
  examples (`UnexpectedEnd`, `InvalidBool`, `InvalidUtf8`, `UnknownVariant`,
  trailing-bytes-under-`runExact`, `decodeRows` failing index).
- Protocol: hex fixtures for each server message (incl. `Ok` with empty
  `ret_value`, both row-hint kinds, an unknown tag → `Unhandled`), byte-exact
  expectations for each client encoder (incl. empty args).
- Pure client: URL assembly (all option combinations), call correlation
  (`allocateCall`/`applyReply`/`drainPending`, wrong-kind reply, unmatched id),
  dispatch routing (reducer rows reach `on_change`, procedure/one-off do not;
  undecodable delete → `RowDecodeFailed`, no partial `on_change`), token
  replacement, subscription-id allocation and no-reuse.
- Failure paths needing a socket but no server: closed port →
  `HandshakeFailed` (NoReconnect) / `Reconnecting(1, …)` (reconnect); `stop`
  idempotent.
- Codegen goldens + generated-type round-trips.

**Live (opt-in `SPACETIMEDB_INTEGRATION=1`):**

- Rust fixture module: one public `widget` table (`id u64` PK auto-inc,
  `name String`, `quantity u32`), private `init` seeding one row, client-callable
  `add_widget`.
- Harness shell script with `serve` (build module, free port, throwaway
  root/data dir, `--in-memory`, publish, print `READY`, block on stdin so
  EOF/trap tears everything down), `describe` (stderr captured), `regenerate`
  (boot → describe → generate → teardown). Owned by one long-lived helper.
- A throwaway TCP proxy with `cut()` / `connections()` to test reconnect.
- The 8 ordered checks from the skill (seed row delivered; describe returns
  schema; token round-trips to same identity; `confirmed=false` accepted;
  one-off query + bad-query `Rejected`; dropped connection comes back
  subscribed as same identity; end-to-end regenerate+use; runtime
  subscribe/unsubscribe). Named `*_check` and handed to the runner explicitly
  so hermetic discovery ignores them.

## Nix / flake / CI

- **flake inputs:** `nixpkgs` (nixos-unstable), `flake-utils`, and
  **`spacetimedb = github:clockworklabs/SpacetimeDB`** — used only to source the
  `spacetime` CLI and Rust wasm toolchain for the live suite. (Implementation
  note: inspect `nix flake show github:clockworklabs/SpacetimeDB` to find the
  exact package attribute for the CLI.)
- **Two dev shells:** `default`/`dev` = hermetic (GHC + cabal-install +
  fourmolu + the `brotli`/`zlib` C libraries); `live` = additionally brings
  `spacetime` + the Rust wasm toolchain from the SpacetimeDB input. The
  Rust/spacetime toolchain is kept **out** of the default shell so CI carries no
  compiler.
- **`.envrc`** with `use flake` so direnv auto-loads the default dev shell;
  `.direnv/` is gitignored.
- **CI (hermetic only):** custom `setup` composite action (Nix install +
  `dist-newstyle` cache keyed on `flake.lock`/`flake.nix`/`*.cabal`/source
  hashes); jobs run `nix develop .#dev --command …` for build, `cabal test`,
  `fourmolu --check`, and the codegen golden check. No live/e2e job — the live
  suite is a local `live`-shell activity.
- `.gitignore`: `dist-newstyle/`, `*.hi`, `*.o`, `result`, `.direnv/`.

## Divergences from the skill (deliberate)

1. **No owner/socket two-role split.** Single `TVar ClientState` + an
   exception-bounded programmatic reconnect loop. The pure state-transition
   core is kept; only the actor partitioning is dropped. (Confirmed with the
   skill's author, who noted the split was skewed by the Gleam/BEAM actor
   model.)
2. **CI is hermetic-only.** No live/e2e CI job (hs-inngest had one); the live
   suite runs locally in the `live` shell, following the skill's toolchain note
   that CI should carry no compiler.
3. **Formatter added** (fourmolu) for deterministic, diff-stable codegen output,
   where hs-inngest vendored none.

## Build order

1. BSATN codec (Layer 1).
2. v2 protocol (Layer 2).
3. Pure client state + transitions (Layer 3a).
4. Client IO shell + reconnect loop (Layer 3b).
5. Codegen (Layer 4).
6. Live harness + Rust fixture + integration checks.
7. Flake / CI / README / `.envrc` polish.
