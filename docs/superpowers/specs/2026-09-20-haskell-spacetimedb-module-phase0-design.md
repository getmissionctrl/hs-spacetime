# Haskell SpacetimeDB Server Modules — Phase 0 Design (Feasibility & Bring-up)

**Date:** 2026-09-20
**Status:** Design approved; spec under review
**Scope of this document:** Phase 0 only. The wider multi-phase program is
summarised for context, but this spec commits to Phase 0 deliverables.

## Background & motivation

`hs-spacetime` is today a **client-only** SDK for SpacetimeDB (v2 binary
WebSocket protocol). SpacetimeDB tables and reducers are defined in a **server
module** that runs *inside* the database. As of SpacetimeDB 2.10 the supported
server-module languages are Rust, C#, C++ (compiled to WebAssembly and run on
Wasmtime) and TypeScript (bundled to JS and run on an embedded V8). Haskell is
not among them.

The goal of the wider program is to make Haskell a **full server-module
language** — define tables from Haskell types, derive the schema, publish, and
have the existing `hs-spacetime` client talk to a Haskell-authored module. This
is a production-SDK ambition and far too large for one spec, so it is
decomposed into phases (below). This document designs **Phase 0**, whose only
job is to answer a hard go/no-go on feasibility and to build a hermetic test
host that unblocks later phases.

### Why not rel8?

rel8 was considered and rejected. It is a PostgreSQL EDSL (opaleye + hasql):
the Haskell process is a *client* that emits Postgres SQL over TCP. It has no
concept of the SpacetimeDB WASM module ABI, of running *inside* the database,
or of the `RawModuleDefV10` BSATN schema. Only its higher-kinded-data pattern
for describing a table as a Haskell record is worth borrowing as a design
reference for the schema DSL — a Phase 2 concern, not Phase 0.

## The feasibility picture (source-pinned to SpacetimeDB v2.10.0)

The ABI surface is **small and tractable**:

- **~25 host imports** under `spacetime_10.0`..`spacetime_10.5`, all C-shaped
  (i32/i64, pointer+len), defined in `crates/bindings-sys/src/lib.rs`. A
  minimal module can target just `spacetime_10.0`.
- **Three required exports** (validated in `crates/core/src/host/wasm_common.rs`):
  - `memory`
  - `__call_reducer__ : (i32, i64,i64,i64,i64, i64,i64, i64, i32, i32) -> i32`
    — args are `(id, sender[4×u64 = Identity], conn_id[2×u64], timestamp_micros,
    args: BytesSource, error: BytesSink)`, returns `0` ok / `HOST_CALL_FAILURE`.
  - `__describe_module__ : (i32) -> ()` — receives a `BytesSink`, into which
    the module streams a **BSATN-encoded `RawModuleDefV10`** via repeated
    `bytes_sink_write`.
- **No allocator export** — data crosses via host-owned `BytesSource` /
  `BytesSink` integer handles (`bytes_source_read` / `bytes_sink_write`), not
  guest pointers.
- **ABI version** is negotiated purely from the `spacetime_10.x` import-module
  names (host v2.10 implements 10.5; same-major, host-minor ≥ module-minor).
  No custom section, no version export.

The **dominant risk is not the ABI** — it is the GHC runtime:

- SpacetimeDB's Wasmtime `Linker` is populated **only** with `spacetime_*`
  functions. There is **no WASI shim**. Rust/C#/C++ modules build for
  `wasm32-unknown-unknown` (freestanding).
- GHC's wasm backend emits a `wasm32-wasi` **reactor** whose garbage-collected
  RTS genuinely imports `wasi_snapshot_preview1` (`fd_write`, `clock_time_get`,
  `random_get`, `proc_exit`, `args_get`, `environ_get`, …). None of those are
  linked by the host, so a stock GHC module **will not instantiate**.
- Mitigating facts: the reactor / `_initialize` entry model **is** compatible
  (the host already calls `_initialize` for C# NativeAOT reactors); and the
  unavailability of clock/random is *aligned* with SpacetimeDB's determinism
  requirement rather than fighting it.

**The make-or-break question Phase 0 must answer:** can we produce a
GHC-compiled wasm module with **zero `wasi_snapshot_preview1` imports** that
instantiates and runs in unmodified SpacetimeDB?

## Program decomposition (context only; not this spec)

Each phase is its own spec → plan → implementation cycle.

- **Phase 0 — Feasibility & bring-up (this spec).**
- **Phase 1 — Server ABI runtime:** foreign imports for `spacetime_10.x`, the
  required exports, `BytesSource`/`BytesSink` marshalling, errno/`i16`
  semantics, `console_log`, identity/timestamp decode.
- **Phase 2 — Schema DSL + `RawModuleDefV10` emitter:** the `spacetimedb/server`
  equivalent (rel8's HKD pattern as design reference), via TH/Generics deriving
  `AlgebraicType` + PK/index/auto-inc.
- **Phase 3 — Table operations API:** typed insert/iter/delete/update/index-scan,
  transactional, with generated-value writeback.
- **Phase 4 — Parity features:** indexes, unique/PK, auto-inc, scheduled
  reducers, lifecycle hooks, procedures + HTTP (10.3), RLS/visibility filters.
- **Phase 5 — Toolchain:** `spacetime build`/`publish` integration; prove the
  existing client codegen round-trips against a Haskell-authored module.

**Crux commitment (decided):** Approach **A** (WASI-stubbed modules on
*unmodified* SpacetimeDB) is the end-state, with Approach **B** (a custom
WASI-enabled test host) run in parallel as the bring-up harness. Approach C
(avoiding the GHC RTS) is rejected — it loses "full Haskell", which is the
point.

## Phase 0 goals & definition of done

**Goal:** a hard go/no-go on Approach A, plus a reusable hermetic test host.
Deliberately **no ergonomics** — hand-written FFI and golden schema bytes are
acceptable. We are proving the runtime, not building the DSL.

**Trivial fixture module** (mirrors the `basic-ts` and existing Rust fixtures so
schemas can be diffed): one table `person { name: string }`, one reducer
`add(name)` that inserts a row.

**Definition of done — go/no-go criteria:**

1. The stubbed module **instantiates** in unmodified SpacetimeDB (zero
   `wasi_snapshot_preview1` imports; verified by artifact, below).
2. `__describe_module__` yields a schema that `spacetime publish` **accepts**.
3. `add("…")` runs, inserts, and the row is **observable via subscription**
   through the existing `hs-spacetime` client.
4. Repeated reducer calls do not leak or corrupt state (basic RTS-reentrancy
   sanity — e.g. N inserts yield N rows across many `__call_reducer__` calls).

A **negative** result (A cannot clear) is a valid Phase 0 outcome: it stops the
program before investment in Phases 1–5, with the blocking WASI import(s)
documented.

## Architecture

Two tracks run concurrently.

### Track B — hermetic test host (the unblocker)

A small **standalone Rust + Wasmtime** host (max fidelity: it is the exact
runtime SpacetimeDB uses). It:

- adds `wasmtime_wasi` (preview1) to the linker;
- registers **stub `spacetime_10.0` functions** backed by an in-memory fake
  datastore — minimally `bytes_sink_write`, `bytes_source_read`, `console_log`,
  `table_id_from_name`, `datastore_insert_bsatn`, `datastore_table_scan_bsatn`,
  `row_iter_bsatn_advance`, `row_iter_bsatn_close`;
- calls `_initialize`, then drives `__describe_module__` (capturing the BSATN
  schema out of the sink) and `__call_reducer__` (args in via a source, error
  out via a sink).

This validates the Haskell runtime layer **without real SpacetimeDB** and
becomes the hermetic rig for Phases 1–4, fitting the repo's hermetic-first
ethos. **Fidelity check for Track A:** the same host with `wasmtime_wasi`
**toggled off** must still instantiate the stubbed module — if it does, real
SpacetimeDB will too.

### Track A — the WASI-stub spike (the real de-risk)

Same fixture module, built to have **zero `wasi_snapshot_preview1` imports**:

1. Enumerate GHC's actual WASI imports (`wasm-tools print` / `wasm-objdump`).
2. Link/rewrite stubs for each: `fd_write` → `console_log` or drop;
   `clock_time_get` / `random_get` → trap (or constant); `proc_exit` → trap;
   `args_get` / `environ_get` → empty; `sched_yield` / `poll_oneoff` → no-op.
   Mechanism: a stub object compiled with the wasm clang, and/or a post-link
   rewrite via `wasm-tools` / `walrus`.
3. **Wizer**-preinitialize so `hs_init` runs at build time and startup is cheap
   and deterministic.
4. Publish to a real local `spacetime start` (via the repo's `.#live`
   harness), call `add` through the **existing hs-spacetime client**, confirm
   the row arrives over a subscription.

### The Haskell module & runtime internals

**Host-import binding via a thin C shim.** GHC's C FFI does not reliably place
imports in a module literally named `spacetime_10.0`, so `cbits/spacetime_abi.c`
+ header declares each host function with
`__attribute__((import_module("spacetime_10.0"), import_name("…")))` (standard
clang/wasm-ld, supported by `ghc-wasm-meta`). Haskell calls these C wrappers via
`foreign import ccall`. The shim is also the home for pointer+len marshalling.

**The two required exports** are C functions in the shim with the exact wasm
signatures, trampolining into Haskell via `foreign export ccall`:

- `__describe_module__(sink)` → Haskell writes the schema into the sink by
  looping `bytes_sink_write` (respecting the in/out length pointer and
  `NO_SPACE`).
- `__call_reducer__(id, sender×4, conn×2, ts, args, error) -> i16` → read args
  from the source (`bytes_source_read`, growing the buffer on
  `BUFFER_TOO_SMALL`), BSATN-decode `{name: string}`, BSATN-encode the row,
  `datastore_insert_bsatn(person_id, …)`, return `0`; on failure write a
  message to the error sink and return `HOST_CALL_FAILURE`.

**Reuse vs. build-new (deliberate minimisation):**

- **Reuse** the repo's existing, property-tested `SpacetimeDB.BSATN.{Decoder,
  Encoder}` for the *row* encode/decode.
- **Do NOT** build a `RawModuleDefV10` encoder in Phase 0. Instead capture the
  **golden BSATN schema bytes** the equivalent Rust/TS `person` fixture emits
  (from its `__describe_module__` output / `spacetime describe`) and have the
  Haskell module reproduce those exact bytes. This tests the ABI plumbing
  end-to-end while deferring the full schema emitter to Phase 2, and gives a
  byte-exact oracle.

**RTS startup:** reactor model + `_initialize`; `hs_init` runs at build time via
Wizer so the deployed module starts cheap and deterministic. GC-under-fuel /
epoch behaviour is explicitly a Phase-1+ concern.

## Toolchain

Add to the Nix dev shell (repo is Nix-first; a new `.#wasm` shell or an
addition to `.#live`):

- GHC's wasm backend via `ghc-wasm-meta`.
- `wizer` (heap pre-initialisation).
- `wasm-tools` (import inspection + post-link rewrite).
- Rust + `wasmtime` crate for the Track B host (already have a Rust/wasm
  toolchain in `.#live` for the fixture module).

## Error handling

- **Host errno / `i16` semantics:** `u16` returns `0` = success, nonzero =
  `Errno`; `i16` returns (`row_iter_bsatn_advance`, `bytes_source_read`) `0` =
  more/ok, `-1` = exhausted, positive = errno cast. The shim surfaces these to
  Haskell as a typed result; Phase 0 handles at least `BUFFER_TOO_SMALL`,
  `NO_SPACE`, `NO_SUCH_TABLE`.
- **Reducer failure:** write the message to the `error` `BytesSink` and return
  `HOST_CALL_FAILURE`; the host aborts the transaction.
- **Panics/traps:** a Haskell exception that escapes → log at panic level via
  `console_log` then trap (aborting the transaction). Phase 0 need not be
  graceful beyond not corrupting state.

## Testing strategy

- **Hermetic (Track B, default CI-eligible):** Rust host instantiates the
  module (WASI on *and* off), asserts `__describe_module__` bytes equal the
  golden schema, drives `add("x")` and asserts the fake datastore received one
  BSATN-encoded `person` row; runs N calls and asserts N rows.
- **Import-list artifact:** a test/asserted check that the **stubbed** module's
  import section contains **no** `wasi_snapshot_preview1` entries (this is
  go/no-go criterion 1, machine-checked).
- **Live (Track A, developer-run, `.#live`):** publish to a real `spacetime
  start`, call `add` via the existing client, assert the row arrives over a
  subscription. Follows the repo's existing hermetic-vs-live split.

## Named risks & mitigations

| # | Risk | Mitigation |
|---|------|------------|
| 1 | GHC FFI can't name the import module `spacetime_10.0` | C shim with `import_module`/`import_name` attributes |
| 2 | Wizer incompatible with GHC wasm reactor | Community precedent; fallback: run `hs_init` at `_initialize` time |
| 3 | RTS calls `clock`/`random` during init | Constant-returning stubs; determinism preserved (init is build-time via Wizer) |
| 4 | `__call_reducer__` `i16` vs host-expected `i32` return | Foreign export returns `Int32` in the i16 value range; validated against host |
| 5 | GHC RTS leaves residual WASI imports that can't be stubbed safely | Enumerate early (step A.1); a genuinely un-stubbable import is a documented no-go |
| 6 | GC nondeterminism under fuel/epoch metering | Out of scope for Phase 0; flagged for Phase 1 |

## Explicitly out of scope for Phase 0

The schema DSL, typed table API, indexes/PKs/auto-inc/scheduling, lifecycle
hooks, procedures/HTTP, RLS, and GC-under-fuel/epoch hardening — all deferred to
Phases 1–5.
