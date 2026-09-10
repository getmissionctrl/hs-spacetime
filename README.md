# hs-spacetime

A native Haskell client SDK for [SpacetimeDB](https://spacetimedb.com), speaking
the **v2 binary WebSocket protocol** (`v2.bsatn.spacetimedb`). Client-only —
server modules are written in Rust/C#/etc. and are out of scope.

## Status / surface coverage

Built bottom-up in four layers, each depending only on the one below:

| Layer | Module(s) | Responsibility |
|-------|-----------|----------------|
| BSATN codec | `SpacetimeDB.BSATN.{Decoder,Encoder,Types}` | little-endian BSATN decode/encode combinators; opaque `Identity`/`ConnectionId`/`Timestamp`/`TimeDuration`/`Uuid` |
| v2 protocol | `SpacetimeDB.Protocol.{RowList,Messages,Frame}` | `BsatnRowList` splitting, every client→/server→ message, frame compression (none/brotli/gzip) |
| client | `SpacetimeDB.Client{,.Types,.State,.Dispatch,.Endpoint,.Connection}` | endpoint URLs, pure client state + call correlation, typed/raw row dispatch, IO shell with an exception-bounded reconnect supervisor |
| codegen | `SpacetimeDB.Codegen{,.Schema}` + `hs-spacetime-codegen` | `spacetime describe --json` → typed Haskell bindings |

Design decision: the client uses a **single durable `TVar ClientState` plus a
programmatic reconnect loop**, not an actor/owner split. State (token,
subscription list with its `query_set_id`s, pending-call registry, id/backoff
counters) outlives any one connection; the socket and its receive loop are
per-connection and disposable, bounded by an exception scope.

## Build & test

Everything runs in a Nix dev shell (GHC + all deps, cabal, fourmolu):

```sh
nix develop .#dev --command cabal build all
nix develop .#dev --command cabal test --test-show-details=direct
nix develop .#dev --command bash -c "fourmolu --mode check \$(git ls-files '*.hs')"
```

The default `cabal test` suite is **hermetic** — no server, no socket to a real
database. (The client's closed-port tests do connect to a dead local port, so a
few connection-refused lines in the log are expected and harmless.)

## Codegen CLI

`hs-spacetime-codegen` reads a `RawModuleDefV10` schema on stdin and writes
Haskell bindings:

```sh
spacetime describe --json <database> | cabal run -v0 hs-spacetime-codegen -- out.hs
# add --skip to emit the supported types and record the rest as `//// Skipped`
```

Unsupported types are fatal by default (one line per offender on stderr, exit
1); `--skip` generates the rest. Output is deterministic and `fourmolu`-clean.

## Quick API sketch

```haskell
import SpacetimeDB

main :: IO ()
main = do
  Right client <-
    start
      ( builder "localhost" 3000 "mydb"
          & withReconnect (Reconnect 500 30000 Nothing)
          & subscribe "SELECT * FROM widget"
          & onEvent print
      )
  callReducer client "add_widget" argsBytes $ \reply -> case reply of
    ReplyReducer outcome -> print outcome
    ReplyCallFailed why -> putStrLn ("call failed: " <> show why)
  -- ... later ...
  stop client
```

**Threading contract:** every callback (`onEvent`, `onError`, typed subscription
sinks, call continuations) runs on one of the client's own threads. Keep them
short and do not call a blocking handle operation from inside one.

## Live suite

The opt-in integration suite runs against a real SpacetimeDB server and is
gated behind `SPACETIMEDB_INTEGRATION=1` in the `.#live` dev shell (which adds
the `spacetime` CLI and a Rust/wasm toolchain):

```sh
SPACETIMEDB_INTEGRATION=1 nix develop .#live --command cabal test --test-show-details=direct
```

`scripts/live-harness.sh` boots a throwaway in-memory server, builds and
publishes the Rust fixture module (`fixture/`), and prints `READY <port> <db>
<root>`. `scripts/live-harness.sh {capture,regenerate} <out>` captures the live
schema JSON / regenerates the golden bindings.

The `.#live` shell ships `rustup` but no default toolchain. Provision it once
(state persists in `/tmp/hs-st-rust`, overridable via `HS_ST_RUSTUP_HOME` /
`HS_ST_CARGO_HOME`):

```sh
nix develop .#live --command bash -c \
  'export RUSTUP_HOME=/tmp/hs-st-rust/rustup CARGO_HOME=/tmp/hs-st-rust/cargo; \
   rustup default stable && rustup target add wasm32-unknown-unknown'
```

Test fixtures are **captured** `spacetime describe --json` output, never
hand-written; the committed golden module is `test/golden/Generated.hs`.

## CI

CI is **hermetic only** by design — it runs `cabal build`, `cabal test`, and
`fourmolu --mode check`, and never builds a compiler or starts a server. The
live suite is developer-run.
