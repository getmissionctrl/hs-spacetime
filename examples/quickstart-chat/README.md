# quickstart-chat — a SpacetimeDB app authored in Haskell

A full, recognizable SpacetimeDB chat application whose **server module is written
entirely in Haskell** on the `hs-spacetime` HKD/`App` authoring surface, and whose
web client is the official [`chat-react-ts`](https://github.com/clockworklabs/SpacetimeDB/tree/master/templates/chat-react-ts)
template running **unmodified** against it.

It demonstrates that the Haskell authoring stack — HKD table rows, `deriveModule`,
and the special scalar types (`Identity`, `Timestamp`, `ConnectionId`, `Maybe`) —
is enough to build a real app: the module derives a schema byte-equivalent to the
Rust/TS reference, cross-compiles to a WASI-free wasm reactor, publishes to a live
server, and serves a stock TypeScript client.

## Layout

```
examples/quickstart-chat/
  server/
    src/Chat.hs            -- the module: User/Message tables, reducers, lifecycle
    app/ChatModule.hs      -- wasm reactor wrapper (foreign exports over chatModule)
    test/                  -- hermetic reducer/lifecycle tests via an in-memory backend
    scripts/build-wasm.sh  -- wasm32-wasi-cabal -> wizer -> WASI-stub -> zero-imports check
    chat-module.cabal      -- separate cabal package (added to the root cabal.project)
  client-web/              -- the chat-react-ts template, TS server removed, scripts repointed
  scripts/
    live-e2e.sh            -- publish the wasm + drive send_message via the CLI (asserts via SQL)
    ui-e2e.sh              -- publish + run the React integration test (full chat flow)
```

## The module

`server/src/Chat.hs` declares the schema as Higher-Kinded-Data rows and one `App`
record; `deriveApp`/`deriveModule` turn it into a `ModuleDef` (schema bytes +
reducer dispatch), no hand-written BSATN:

```haskell
data User f = User
  { identity :: Column f Identity     '[ 'Pk]
  , name     :: Column f (Maybe Text) '[]
  , online   :: Column f Bool         '[]
  }
data Message f = Message
  { sender :: Column f Identity  '[]
  , sent   :: Column f Timestamp '[]
  , text   :: Column f Text      '[]
  }
data App = App
  { user               :: Table User
  , message            :: Table Message
  , setName            :: Reducer SetNameArgs        -- set_name
  , sendMessage        :: Reducer SendMessageArgs    -- send_message
  , init               :: LifecycleHook 'Init
  , clientConnected    :: LifecycleHook 'OnConnect   -- client_connected
  , clientDisconnected :: LifecycleHook 'OnDisconnect
  }
```

Behavior mirrors the official reference: `set_name` rejects empty names and errors
for an unknown user; `send_message` rejects empty text and stamps each message with
the sender + timestamp; `client_connected`/`client_disconnected` maintain per-user
presence; `init` is a no-op.

## Running it

All native commands run in the `.#dev` nix dev shell; the wasm build needs `.#wasm`;
publishing/generation/live tests need `.#live`.

### 1. Hermetic module tests (no server)

```bash
nix develop .#dev --command cabal test chat-module-test
```
9 examples: reducer dispatch through an in-memory fake backend, validation errors,
and lifecycle presence.

### 2. Build the wasm reactor

```bash
nix develop .#wasm --command bash examples/quickstart-chat/server/scripts/build-wasm.sh
```
Cross-compiles with `wasm32-wasi-cabal` (depending on the public `spacetime-server`
+ `bsatn` sublibraries), Wizer-snapshots the post-init heap, stubs the WASI imports,
and asserts **zero `wasi_snapshot_preview1` imports**. Output:
`server/dist/chat-module.nowasi.wasm` (gitignored).

### 3. Live server round-trip (CLI)

```bash
nix develop .#live --command bash examples/quickstart-chat/scripts/live-e2e.sh
```
Boots a throwaway server, `spacetime publish -b`es the wasm as `quickstart-chat`,
calls `send_message`, and asserts the row via SQL (and that empty text is rejected,
with no wasm traps).

### 4. Generate the TypeScript bindings from the wasm

```bash
cd examples/quickstart-chat/client-web
nix develop .#live --command npm install
nix develop .#live --command npm run spacetime:generate   # spacetime generate --bin-path ../server/dist/chat-module.nowasi.wasm
```
The generated `src/module_bindings/` differ from the upstream template's only
cosmetically (prettier quote style + declaration ordering); the schema — table
fields/types and reducer args — is identical, which is the proof the Haskell-derived
schema matches the reference.

### 5. Full UI end-to-end (React client ↔ live module)

```bash
nix develop .#live --command bash examples/quickstart-chat/scripts/ui-e2e.sh
```
Publishes the wasm to a server on `:3000`, then runs the client's vitest integration
test, which connects over WebSocket and drives the whole flow: connect →
`client_connected` creates the user → `set_name` → the name renders → `send_message`
→ the message renders.

### 6. Run the app for real

```bash
cd examples/quickstart-chat/client-web
# with a server running + the module published as `quickstart-chat` on ws://localhost:3000:
nix develop .#live --command npm run dev
```
Open the printed URL. Set a name, send a message, and open a second tab — both
appear under **Online**, and closing one moves it to **Offline** (presence via the
lifecycle reducers). The client is env-driven (`VITE_SPACETIMEDB_HOST` default
`ws://localhost:3000`, `VITE_SPACETIMEDB_DB_NAME` default `quickstart-chat`).

## What the client changes from upstream

Only three things: the bundled TypeScript server module (`spacetimedb/`) is deleted
(we publish the Haskell wasm instead), the `spacetimedb` npm dependency is pinned to
a published version (the template used a monorepo `workspace:*` ref), and the
`package.json` module scripts point at the prebuilt wasm via `--bin-path`. Everything
under `src/` is the upstream template verbatim, aside from relaxing one over-strict
test assertion (`getByText` → `getAllByText` for a name that renders in two places).

## Haskell TUI client

A terminal chat client written in Haskell (Brick), reusing the server module's
typed handles. See [`client-tui/README.md`](client-tui/README.md). Quick start
(with a published module + running server):

    STDB_HOST=127.0.0.1 STDB_PORT=3000 STDB_DB=quickstart-chat \
      cabal run chat-tui:exe:chat-tui
