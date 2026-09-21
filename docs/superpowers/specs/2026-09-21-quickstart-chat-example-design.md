# Design: quickstart-chat example (Haskell backend → Next.js frontend)

**Status:** approved design, pre-plan
**Date:** 2026-09-21
**Scope:** the flagship end-to-end example for this repo — a SpacetimeDB
`quickstart-chat` module authored in Haskell on the HKD/`App` surface, published
live, and driven by both a typed Haskell client and a Next.js web UI. One spec,
four sequenced phases. Correctness is proven by the **live round trip**, not by a
Rust schema oracle.

## Goal

Show that the merged authoring stack (HKD rows + `App`/`deriveModule`, the special
scalar types `Identity`/`Timestamp`/`ConnectionId`/`Maybe`) is enough to build a
real, recognizable SpacetimeDB application entirely in Haskell, and that a stock
SpacetimeDB TypeScript client + Next.js UI talk to it unmodified. The example
doubles as living documentation for module authors.

The headline acceptance criterion: **a user opens the Next.js app, sets a name,
sends a message, and sees it appear — served by the live GHC-wasm Haskell
module.** Presence (online/offline) updates as clients connect/disconnect.

## Non-goals

- No Rust oracle / byte-match for the chat schema. The special-type byte-shapes
  are already golden-proven at the library level (`phase2/golden/probe.schema.bsatn`);
  the chat module's correctness is demonstrated by the live round trip, not a
  captured golden. (Decided explicitly — see "Testing".)
- No new library features. If a genuine gap surfaces (e.g. an ergonomic upsert
  helper), it is flagged during implementation and split into its own spec; the
  example is built on the surface as it exists today.
- No production hardening of the web UI (auth, styling polish, deployment). The
  UI is a minimal, faithful adaptation of the official quickstart-chat frontend.

## Prior art in this repo (what we build on)

- **Authoring surface** (`SpacetimeDB.Server`, `HKD.hs`, `Derive.hs`): HKD table
  rows `data T f = T { c :: Column f A '[attrs] }`, an `App` record whose fields
  are `Table`/`Reducer`/`LifecycleHook` handles, `deriveApp`, and
  `deriveModule app handlers`. Field order = schema/dispatch order. See
  `docs/superpowers/specs/2026-09-21-hkd-module-derivation-design.md`.
- **Special types** (merged): `Identity`, `Timestamp`, `ConnectionId`, `Maybe a`
  are usable in `Column` fields and reducer-argument records.
- **Wasm reactor pattern** (`server/example/WidgetModule.hs`): a module exports
  `hs_describe`/`hs_call_reducer` via `foreign export ccall` (`runDescribe`,
  `runCallReducer` from `SpacetimeDB.Server.ABI`); built to wasm under `.#wasm`
  behind the cabal `wasm` flag.
- **Live-publish is already proven.** `phase0/module/Module.hs` + commit
  `2144792` ("phase0: M-A — live publish + reducer round-trip; record go/no-go")
  established that a GHC-wasm SpacetimeDB module builds, publishes via
  `spacetime publish`, and dispatches reducers against a real host. Phase 2 reuses
  that path; the biggest end-to-end risk is therefore already retired.
- **Live harness** (`scripts/live-harness.sh`, `test/SpacetimeDB/Live/Harness.hs`):
  boots a throwaway in-memory server, publishes a module, exposes
  `describe`/`capture`/`regenerate`. Gated by `SPACETIMEDB_INTEGRATION=1`. Today
  it publishes a Rust fixture; Phase 2 teaches it (or a sibling script) to publish
  the Haskell chat wasm.
- **Typed Haskell client** (`SpacetimeDB.Client`, `Client.Typed` with
  `callTyped`/`subscribeTable`): the Phase 3 round-trip client.
- **Codegen** (`hs-spacetime-codegen`): generates *Haskell* bindings from a
  schema. Not used for the web UI (that uses the stock TS SDK), but noted so the
  reader isn't confused about which codegen is which.

## Repo layout (new)

```
examples/quickstart-chat/
  server/
    ChatModule.hs          -- the module (tables, reducers, lifecycle, wasm exports)
  client-hs/
    Main.hs                -- typed Haskell client round-trip (Phase 3)
  client-web/
    ...                    -- Next.js app + generated TS bindings (Phase 4)
  README.md                -- narrative walkthrough across the four phases
```

Hermetic tests live under the existing `test/` tree as a new spec module
(registered in `hs-spacetime.cabal` / `test/Spec.hs`). Cabal targets for
`ChatModule` (wasm example, behind the `wasm` flag, mirroring
`widget-module-example`) and the `client-hs` executable are added.

## The module (Phase 1)

Canonical quickstart-chat shape, Haskell-idiomatic field names (never-prefixed
fields; `deriveApp` maps camelCase → snake_case):

```haskell
data User f = User
  { identity :: Column f Identity   '[ 'Pk]
  , name     :: Column f (Maybe Text) '[]
  , online   :: Column f Bool       '[]
  }
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (User 'Value)

data Message f = Message
  { sender :: Column f Identity  '[]
  , sent   :: Column f Timestamp '[]
  , text   :: Column f Text      '[]
  }
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (Message 'Value)

newtype SetNameArgs     = SetNameArgs     { name :: Text } deriving stock Generic deriving anyclass SpacetimeType
newtype SendMessageArgs = SendMessageArgs { text :: Text } deriving stock Generic deriving anyclass SpacetimeType

data App = App
  { user               :: Table User
  , message            :: Table Message
  , setName            :: Reducer SetNameArgs        -- set_name
  , sendMessage        :: Reducer SendMessageArgs    -- send_message
  , init               :: LifecycleHook 'Init
  , clientConnected    :: LifecycleHook 'OnConnect   -- client_connected
  , clientDisconnected :: LifecycleHook 'OnDisconnect
  }
  deriving stock (Generic)
```

Handler behavior (all in `ReducerM`, sender/timestamp from `ask`'s
`ReducerContext`):

- `setName` — `throwError` if the trimmed name is empty; otherwise upsert the
  sender's `User.name` (delete-then-insert the row keyed by `ctx.sender`, since
  the retained low-level surface has no dedicated update; a helper may be
  proposed if this reads poorly).
- `sendMessage` — `throwError` if the text is empty; otherwise
  `insertRow message (Message ctx.sender ctx.timestamp text)`.
- `init` — no-op (no seed data).
- `clientConnected` — upsert `User { identity = ctx.sender, online = True }`,
  preserving any existing `name`.
- `clientDisconnected` — set that user's `online = False`.

Wasm exports mirror `WidgetModule.hs` exactly (`hs_describe`, `hs_call_reducer`).

### Upsert detail (called out, not hand-waved)

`User` rows are keyed by `identity` (Pk). "Upsert" = `scanRows`/lookup by
identity, then `deleteRow` the old + `insertRow` the new (or `insertRow` if
absent). This is the one place the example does real logic; the plan spells out
the exact sequence. If it proves clumsy enough to warrant a library helper, that
is a separate spec, not smuggled into this one.

## Phases

**Phase 1 — module + hermetic tests.** `ChatModule.hs` compiles (native + wasm
flag). A new `ChatModuleSpec` drives reducers through a fake `Backend`:
`send_message` inserts exactly one `Message`; empty `send_message`/`set_name`
error; `client_connected` marks a user online; dispatch ids line up with `App`
field order. These are sanity checks over behavior, **not** a schema golden.

**Phase 2 — live integration.** Teach the harness to build the chat wasm (`.#wasm`)
and `spacetime publish` it (reusing the phase0 path). A gated
(`SPACETIMEDB_INTEGRATION=1`) test: publish, call `set_name` + `send_message`
(via `spacetime call`), then `spacetime sql`/`describe` to assert the `User`/
`Message` rows exist with the expected values. This is the first live proof the
Haskell chat module runs end-to-end.

**Phase 3 — typed Haskell client round trip.** `client-hs/Main.hs` connects with
`SpacetimeDB.Client.Typed`, subscribes to `user`/`message`, calls
`app.sendMessage`, and asserts the row echoes back over the subscription. Wrapped
in a gated integration test. Demonstrates the Haskell *client* SDK against a
Haskell *server* module — both halves of the stack in one language.

**Phase 4 — TS bindings + Next.js UI.** `spacetime generate --lang typescript`
against the published module into `client-web/src/module_bindings`; a minimal
Next.js chat page (name input, message list, send box) wired to the stock
`@clockworklabs/spacetimedb-sdk`, adapted from the official quickstart. The spec
documents the exact commands and a manual smoke checklist; this is the
**headline round-trip proof**: the UI, talking only through generated TS bindings
and the public protocol, drives the live Haskell module.

## Testing strategy

| Layer | When | What |
|---|---|---|
| Hermetic unit (`ChatModuleSpec`) | always (`.#dev`) | reducer dispatch via fake `Backend`; validation errors; lifecycle effects; dispatch-id ordering |
| Live integration (Phase 2) | gated `SPACETIMEDB_INTEGRATION=1` | publish Haskell wasm; `spacetime call` reducers; assert rows via SQL/describe |
| Live client (Phase 3) | gated | Haskell typed client subscribe + call round trip |
| E2E UI (Phase 4) | manual/documented | Next.js UI drives the live module through the full chat flow |

**No Rust chat oracle / no chat schema golden** — deliberate. The library already
guarantees byte-correct special types via the probe golden; the example proves
*itself* by working end-to-end, which a byte-match cannot (a schema can match
bytes and still mis-behave at runtime). This is the "prove it via the round trip"
decision.

## Sequencing within the single spec

Although one spec, the phases are built and validated in order — each written
against the working artifact of the prior one (module exists → publish it →
client talks to it → UI talks to it). The implementation plan will present the
phases as ordered task groups with their own verification gates, so work still
lands and reviews incrementally.

## Risks / open questions

- **Upsert ergonomics.** No update primitive; delete-then-insert by Pk. Spelled
  out in the plan; a helper is a separate spec if warranted. *(Primary logic risk.)*
- **Wasm module size / build under `.#wasm`.** GHC-wasm reactor builds already
  work for widget/person/phase0; the chat module is only marginally larger.
- **`spacetime generate --lang typescript` fidelity** against a Haskell-authored
  module. The schema is byte-identical to a Rust-authored equivalent (library
  guarantee), so stock TS generation should behave; Phase 4 smoke-verifies it.
- **Presence semantics** (`client_connected`/`client_disconnected`) depend on the
  host delivering those lifecycle calls with the right `ctx.sender`; validated in
  Phase 2/3.

## Success criteria

1. `examples/quickstart-chat/server/ChatModule.hs` builds native and to wasm;
   `ChatModuleSpec` green in the always-on suite.
2. Phase 2 gated test publishes the Haskell module live and observes `set_name` /
   `send_message` effects.
3. Phase 3 gated test completes a typed Haskell client subscribe/call round trip.
4. Phase 4: the Next.js UI, using generated TS bindings, drives the live Haskell
   module through set-name → send → receive, with presence updating — per the
   documented smoke checklist.
5. `README.md` walks a reader from module source to running UI.
