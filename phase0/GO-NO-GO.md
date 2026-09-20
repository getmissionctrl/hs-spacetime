# Phase 0 — Milestone M-A Go/No-Go

**Verdict: GO.** A WASI-free, Haskell-derived SpacetimeDB module publishes to an
unmodified local SpacetimeDB server (v2.10.0) and a reducer round-trips: the
`add` reducer decodes a BSATN argument, inserts a `person` row, and the row is
observable via `spacetime sql`. Repeated calls do not corrupt or leak.

Reproduce end-to-end:

```
nix develop .#wasm --command bash -c 'phase0/scripts/live-check.sh'
```

## Module under test

- File: `phase0/module/person-module.nowasi.wasm`
- Size: **1,373,244 bytes (~1.31 MiB)**
- SHA-256: `cdfe8b62ff71be56a478d425a25777fea6b55580e176a95ac0a6ef5b1c2714b9`
- Imports: **only** the 4 `spacetime_10.0` host funcs — `table_id_from_name`,
  `datastore_insert_bsatn`, `bytes_source_read`, `bytes_sink_write`.
  **Zero `wasi_snapshot_preview1` imports** (machine-checked by
  `phase0/scripts/check-imports.sh`).
- Exports: `memory`, `__describe_module__`, `__call_reducer__` (plus the 18
  merged WASI-stub exports, which are inert). **No `_initialize` export** — Wizer
  consumed it after snapshotting the post-`hs_init` heap.
- Represents one public table `person { name: string }` and one reducer
  `add(name: String)`.

## Server setup

- `spacetime` CLI v2.10.0 (commit `b42765a`), `spacetimedb-standalone` v2.10.0.
- Throwaway server per run: `spacetime start --in-memory --non-interactive`
  bound to a random loopback port, with a private `$HOME`/`--data-dir` under a
  `mktemp -d` so the user's real config/identity is never touched. Torn down on
  exit.
- Auth is non-interactive via `--anonymous` on publish/call/sql (a fresh
  ephemeral identity; the anonymous caller is the database owner and is
  authorized to call the reducer). No `spacetime login` needed for the CLI path.

## Publish mechanism

Publishing a **prebuilt** wasm uses `spacetime publish -b/--bin-path <wasm>`
(instead of `-p <project>`, which would rebuild). No Rust project was built; our
Haskell-derived `.wasm` was uploaded verbatim. The CLI confirms:

```
(WASM) Skipping build. Instead we are publishing .../person-module.nowasi.wasm
```

## Go/No-Go criteria

### 1. Instantiates in unmodified SpacetimeDB (zero WASI imports) — PASS

`check-imports.sh` proves zero `wasi_snapshot_preview1` imports. On the live
server the module launches and initializes cleanly (server log):

```
launching module db=... host_type=Wasm
init database
INFO: Creating table `person`
INFO: Database initialized
```

The absent `_initialize` did **not** matter: SpacetimeDB's reactor host no-ops
when `_initialize` is missing, and the RTS state is already baked into the Wizer
snapshot, so `hs_init` never re-runs on the server.

### 2. `spacetime publish` accepts the schema — PASS

```
Created new database with name: person-hs, identity: c200...
```

`spacetime describe person-hs --json` shows the server parsed the schema exactly:
a `person` table over product `{ name: String }`, and reducer `add` with
`params { name: String }`, `ClientCallable`, `ok_return = Product{}`,
`err_return = String`. The golden 129-byte BSATN schema emitted by
`__describe_module__` is accepted as-is by the real host.

### 3. `add("carol")` runs, inserts, and the row is observable — PASS

```
== call add("carol") ==
== SELECT * FROM person ==
 name
---------
 "carol"
```

(The stored value renders as `"carol"` because the row's BSATN is a bare string;
the CLI's SQL formatter shows the quoted string. The row exists and is queryable,
which is the criterion.)

### 4. Reentrancy: ~20 calls, no corruption/leak — PASS

20 further `add()` calls with distinct names, then:

```
== SELECT COUNT(*) AS n FROM person (expect 21) ==
 n
----
 21
== scan server log for wasm traps ==
OK: no trap-like lines in server log
GO: row count 21 == expected 21
```

Count matches (1 + 20). No traps/panics/`unreachable` in the server log across
21 reducer invocations. Memory footprint was a non-issue — the ~1.3 MiB module
runs comfortably under SpacetimeDB's default wasm memory limits; no
memory/fuel/instantiation errors appeared.

## The bug this run found and fixed (ABI conformance)

The first live `add` call failed with HTTP **530** and the module logged
`args len=0` — the reducer received **zero** argument bytes even though the CLI
sent `"carol"`. Root cause was in `Module.hs`'s `readSource`:

SpacetimeDB's host `bytes_source_read` (see
`crates/core/src/host/wasmtime/wasm_instance_env.rs`) writes the bytes read into
the buffer **and updates the length** *before* deciding its return code, and it
returns **`-1` together with the final chunk** that exhausts the source (it frees
the source once empty). The old `readSource` treated `rc == -1` as "no bytes this
call" and discarded the just-written bytes, so a source drained in a single read
(the common case, 9 bytes ≤ 4 KiB buffer) yielded an empty argument buffer,
decode failed, and the reducer returned errno 1 → 530.

The hermetic Track-B host (`phase0/host/src/lib.rs`) masked this: it returns
`-1` only when the source is **already** empty on entry and returns `0` (never
`-1`) on the last non-empty chunk — so the old code happened to work there. This
is a genuine host-behavior divergence between the hermetic stub and real
SpacetimeDB.

Fix: always harvest the `n` bytes written on every call (including the `rc == -1`
call), then stop iff `rc == -1`. After the fix, the reducer receives
`args len=9 hex=050000006361726f6c` (BSATN string "carol"), decodes it, and
inserts. This is the one behavioral change to the module in this milestone; the
`.nowasi.wasm` was regenerated from it.

## Findings for SpacetimeDB / ABI

- `bytes_source_read` contract (confirmed against v2.10 host source): status
  `0` = read some, more may remain; status `-1` = source now exhausted **and**
  this call may still have written bytes. Modules must consume bytes on the `-1`
  call. The source is auto-freed on exhaustion.
- `spacetime call <db> add '"carol"'` JSON-encodes the arg against the reducer's
  declared param product `{ name: String }`. For a single string field the BSATN
  is byte-identical to a bare string, so our bare-string decoder interoperates.
- `spacetime sql` requires aggregate expressions to carry a column alias
  (`SELECT COUNT(*) AS n ...`); a bare `COUNT(*)` returns HTTP 400
  "Aggregate expressions must have column aliases".
- `spacetime logs` does **not** accept `--anonymous` and requires an authorized
  identity for a non-owner; use the CLI SELECT for observation, or run `logs`
  with the owning identity.
- No memory-limit, fuel, or ABI-version rejection was encountered; the host's
  `spacetime_10.0` import namespace matched the module's imports exactly.

## Banked Phase-1 findings (from producing this module)

1. **Mandatory C-shim FFI indirection.** GHC's wasm FFI always emits `foreign
   import ccall` imports into wasm import module **`env`**, with no way to target
   the host's required `spacetime_10.0` import module. The module therefore
   cannot call the host functions directly from Haskell. The workaround (see
   `phase0/module/cbits/spacetime_abi.c` / `.h`) is a thin C shim: C wrapper
   functions (`shim_*`) that Haskell calls as ordinary intra-module calls, and
   the wrappers forward to the real host imports declared with
   `__attribute__((import_module("spacetime_10.0"), import_name(...)))`. Phase 1
   must generate this shim layer for every host function a module uses.
2. **`__preinit__` describer registration.** Real SpacetimeDB modules populate
   the static describer list via `__preinit__20_register_describer_*` exports
   that the reactor host calls (sorted) before `_initialize`; if they are not
   called, `__describe_module__` returns an empty module. Phase 0 sidesteps this
   by emitting a fixed golden schema directly from `__describe_module__`, but a
   general Phase-1 module generator must emit and honor the `__preinit__`
   registration mechanism.
