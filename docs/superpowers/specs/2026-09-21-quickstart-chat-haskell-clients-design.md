# quickstart-chat Haskell Clients — Design

**Date:** 2026-09-21
**Status:** Approved (design); pending spec review before planning
**Worktree/branch:** `quickstart-chat-clients` (under `.worktrees/`)

## Goal

Add two Haskell clients for the existing `quickstart-chat` SpacetimeDB example:

1. A **terminal (TUI) client** — native, built on the existing Haskell client SDK.
2. A **browser (web) client** — compiled to WebAssembly, where **Haskell owns the WebSocket** via GHC's async JavaScript FFI.

Both connect to the Haskell-authored `quickstart-chat` module and reuse the *same* typed handles from the server module, so calls are compile-checked against the schema. End state: a minimal-but-real Haskell web chat client and a Haskell TUI chat client, both round-tripping live against the Haskell backend.

## Non-Goals (YAGNI)

- No UI polish / no mirroring the `chat-react-ts` styling (functional-minimal views only).
- No native compression in wasm (negotiate `CompNone`).
- No new Rust oracle for the chat schema — prove via live round-trip against the Haskell module.
- No rewrite of the shipped native client SDK runtime (`Client.hs`/`Connection.hs`).
- No reconnection UX beyond connect-once (a manual reconnect is out of scope for v1).

## Shared Concepts

Both clients target the published `quickstart-chat` module:

- **Tables:** `user` (`identity` PK, `name :: Maybe Text`, `online :: Bool`), `message` (`sender :: Identity`, `sent :: Timestamp`, `text :: Text`).
- **Reducers (wire names):** `set_name` (`SetNameArgs {name :: Text}`), `send_message` (`SendMessageArgs {text :: Text}`).
- **Typed handles:** imported from `Chat` in the `chat-module` package — `Chat.app`, `Chat.User`, `Chat.Message`, `Chat.SetNameArgs`, `Chat.SendMessageArgs`.
- **Subscriptions:** `SELECT * FROM user` and `SELECT * FROM message`.
- **Rendering:** build an `Identity → name` map from the `user` rows; render each message as `name: text` (fall back to a short identity prefix when a name is absent).
- **Config:** `CompNone`, connect-once, fresh identity/token issued by the server on connect.

## Architecture

### Component 1 — TUI client (native)

**Package:** `examples/quickstart-chat/client-tui/` (new cabal package, native executable `chat-tui`).

**Dependencies:** the existing `hs-spacetime` client library (unchanged) + `chat-module` (typed handles) + `brick` + `vty`.

**Design:**
- Reuse the SDK as-is: `builder` → `subscribeTable app.user`/`app.message` → `start` → `callTyped app.sendMessage` / `app.setName`.
- Brick `App` with:
  - a message pane (scrollback of `name: text`),
  - a status line (connection state + local identity/name),
  - an input line.
- Live updates: the SDK's typed sinks / `onEvent` push into a `Brick.BChan`; `customMain` renders on each `AppEvent`.
- Key handling: `Enter` sends the current input as `send_message`; a leading `/name <x>` calls `set_name`; `Esc`/`Ctrl-C` quits.
- A small **pure core** module holds view state (message list, name map, input buffer) and the reducers over events, so it is unit-testable without a terminal or a connection.

**No SDK changes.** Ships first — quick win, independently proves typed-handle reuse.

### Component 2 — browser client (wasm)

**New wasm-safe sublibrary `spacetime-client-core`** (added to the existing client cabal; the shipped native `library` and `Connection.hs` stay untouched):
- Exposes the already-pure layers: `SpacetimeDB.Client.Endpoint`, `.Types`, `.State`, `.Dispatch`, `SpacetimeDB.Protocol.*`, `SpacetimeDB.Client.Typed`.
- Depends only on wasm-safe packages (`base`, `bytestring`, `text`, `containers`, `bsatn`, `spacetime-server`) — **no** `websockets`/`wuss`/`network`/`zlib`/`brotli`.
- Buildable both natively and under `-fwasm`.

**New wasm reactor executable** `examples/quickstart-chat/client-web-hs/` (behind `flag(wasm)`, `buildable: False` otherwise):
- Depends on `spacetime-client-core` + `chat-module`.
- **Haskell owns the socket** via `foreign import javascript`:
  - open: `new WebSocket(url, "v1.bsatn.spacetimedb")` (subprotocol as required by the SpacetimeDB WS protocol),
  - inbound: an `onmessage` callback (`foreign import javascript "wrapper"`) pushes each binary frame's bytes into an inbound `TQueue`,
  - outbound: a drain loop reads an outbound `TQueue` and calls `ws.send(bytes)`.
- A **browser-specific runtime** (~100 lines) reuses the pure `decodeFrame` (`Protocol.Frame`), `Dispatch`, `State`, and `Client.Typed` glue to turn inbound frames into view/state updates and to encode outgoing reducer calls. The native `readerLoop`/`writerLoop` are intentionally *not* ported (blocking receive + native threads); a callback-driven loop is the correct shape here.
- **View:** Haskell builds the message-list HTML string and hands it to JS (mc-finance's bytes/string-out marshalling) to set a `<div>`'s `innerHTML`. Exported Haskell functions handle "send" (from the message box) and "set name" (from the name field) by enqueuing reducer calls.

**Build pipeline** (`examples/quickstart-chat/client-web-hs/scripts/build-web-hs.sh`):
1. `wasm32-wasi-cabal build -fwasm exe:chat-web` with reactor link flags (`-no-hs-main -optl-mexec-model=reactor`) and the JSFFI exports.
2. Run ghc-wasm-meta's `post-link.mjs` (located under `$(wasm32-wasi-ghc --print-libdir)`) on the linked wasm to emit the `ghc_wasm_jsffi` JS glue module.
3. A static HTML host page instantiates the module with `browser_wasi_shim` (WASI) **plus** the JSFFI import object, calls `_initialize`/`hs_init`, then calls the exported `startClient(host, db)`.
4. Serve with a plain static file server (e.g. `python -m http.server`), host configurable via query string / env, defaulting to the local published module.

### De-risking & fallback

- **First implementation task is a spike:** a minimal "Haskell-in-wasm opens a WebSocket, receives one frame, updates the DOM" artifact that proves async JSFFI + `browser_wasi_shim` + `post-link.mjs` work in *this* repo's `.#wasm` shell — **before** building the chat client on top.
- **Defined fallback:** if the async/STM runtime cannot be driven cleanly in the single-threaded wasm reactor, the browser client degrades to a **Hybrid** shape — JS owns the socket; Haskell still owns all protocol handling, BSATN decode, state, and view (bytes-in / outgoing-bytes-and-view-out). Same UI, same Haskell protocol code; only the socket moves to JS. This decision is surfaced at the spike checkpoint, not taken silently.

## Toolchain Facts (verified)

- Wasm GHC: **9.12** via `ghc-wasm-meta` `all_9_12` (`github:haskell-wasm/ghc-wasm-meta`). GHC 9.12 supports async JSFFI (`foreign import javascript`, Promise-await with the RTS scheduler, `foreign import javascript "wrapper"` callbacks).
- `post-link.mjs` (JSFFI glue generator) ships inside the GHC wasm lib dir; the flake does not currently wire it — the browser build script locates and invokes it.
- The existing server wasm pipeline (Wizer + WASI-stub + `spacetime_10.0` host imports) is separate and untouched; the browser pipeline uses `browser_wasi_shim` for WASI instead.
- The native client library is `buildable: False` under `+wasm` and depends on native-only `websockets`/`wuss`/`network`/`zlib`/`brotli`; the new `spacetime-client-core` sublibrary avoids all of these.

## Testing

- **TUI:** hermetic unit tests over the pure view core (message rendering, `Identity → name` map, input/`/name` handling); an opt-in live e2e (connect to a published module, `send_message`, observe the echoed row) gated like the existing `IntegrationCheck` (`SPACETIMEDB_INTEGRATION=1`).
- **Browser:** hermetic Haskell tests over the frame-handling/view core in `spacetime-client-core` (decode a canned server frame → expected view state). A scripted/manual browser smoke check grows out of the spike artifact (load page, connect to the live module, send a message, see it appear). No automated headless-browser suite in v1.
- **Regression:** the native `hs-spacetime` library and the server wasm build must remain green (no changes to their sources).

## Packaging & Order

- **One spec, two components.** Build order:
  1. `spacetime-client-core` sublibrary (extract/expose pure layers; native + wasm build green).
  2. TUI client (native) — full vertical slice, ships first.
  3. Browser spike (async JSFFI WebSocket smoke test) — checkpoint + fallback decision.
  4. Browser chat client on top of the spike.
- All new code under `examples/quickstart-chat/` except the `spacetime-client-core` sublibrary (added to the existing client cabal package) and the browser build script.

## File Structure (planned)

- `spacetime-client-core` sublibrary stanza — added to the existing client `.cabal` (`hs-spacetime.cabal`), reusing `src/` sources via a curated `exposed-modules`.
- `examples/quickstart-chat/client-tui/` — `chat-tui.cabal`, `src/` (pure core), `app/Main.hs` (Brick), `test/`.
- `examples/quickstart-chat/client-web-hs/` — `chat-web.cabal` (wasm exe behind `flag(wasm)`), `src/` (browser runtime + JSFFI), `app/`, `web/` (HTML host + JS glue), `scripts/build-web-hs.sh`, `test/`.
- `examples/quickstart-chat/README.md` — extend with TUI + browser sections.
