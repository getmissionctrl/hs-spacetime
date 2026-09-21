# quickstart-chat Example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the flagship `quickstart-chat` example — a SpacetimeDB chat module authored entirely in Haskell on the HKD/`App` surface, published live as a GHC-wasm module, and driven unchanged by the official `chat-react-ts` web client.

**Architecture:** A self-contained `examples/quickstart-chat/` tree. The **server** is its own cabal package (`chat-module`) exposing a native-testable `chatModule :: ModuleDef` plus a wasm reactor wrapper; it is built to wasm via the proven phase0 pipeline (`wasm32-wasi-ghc` → `wizer` → WASI-stub) and published with `spacetime publish -b`. The **web client** is the upstream `chat-react-ts` template vendored verbatim except for deleting its bundled TS server and repointing its scripts at our wasm. TS bindings are produced by `spacetime generate --lang typescript --bin-path <wasm>`. Server (Groups A/B) and client (Group C) proceed in parallel against a shared, byte-identical schema contract; Group D wires them live; Group E is end-to-end + docs.

**Tech Stack:** GHC 9.10.3 native (`.#dev`) for the module + hermetic tests; `ghc-wasm-meta` 9.12 + `wizer` + `wasm-tools` (`.#wasm`) for the wasm; `spacetime` CLI (`.#live`) for publish/generate/live tests; Node 20 + Vite + React 18 + `spacetimedb` npm SDK for the client. hspec, fourmolu.

**Conventions:**
- Native commands run in `.#dev` (e.g. `nix develop .#dev --command cabal test chat-module-test`). Wasm build runs in `.#wasm`; live/generate/publish run in `.#live`.
- Field convention: `DuplicateRecordFields` + `NoFieldSelectors` + `OverloadedRecordDot`, `deriving stock (…, Generic)`; never prefix field names.
- Format touched Haskell with `nix develop .#dev --command fourmolu -i <files>` before each commit; format touched TS with the client's `npm run format`.
- Commit trailers (append to every commit message):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016WZ3cT8fjfvnPjMTPJFi54
  ```
- TDD loop (write test → see it fail → implement → see it pass → commit) is the source of truth for Group A. Groups B–E are scripted/mechanical: each step gives exact commands and expected output.
- **Nix isolation:** all work happens on branch `quickstart-chat-example` in the gitignored worktree `.worktrees/quickstart-chat`, so the main tree (watched by vf-haskell) is untouched until a single merge. No `flake.nix` change is made.

**Resolved facts from discovery (do not re-litigate):**
- The upstream template is **Vite + React + TS** (`templates/chat-react-ts` at pinned SpacetimeDB rev `b42765a`), *not* Next.js. Its reference schema is our exact target:
  - `user` (public): `identity: Identity [Pk]`, `name: Option<String>`, `online: bool`.
  - `message` (public): `sender: Identity`, `sent: Timestamp`, `text: String`.
  - Reducers: `set_name({name})`, `send_message({text})`. Lifecycle: `init`, `client_connected`, `client_disconnected`.
- Reference behavior (mirror exactly, so generated bindings match the committed ones):
  - `set_name`: reject empty name (`throwError "Names must not be empty"`); look up the sender's `User` by `identity`; if absent `throwError "Cannot set name for unknown user"`; else update `name`.
  - `send_message`: reject empty text (`throwError "Messages must not be empty"`); insert `Message { sender = ctx.sender, sent = ctx.timestamp, text }`.
  - `client_connected`: if a `User` with `ctx.sender` exists, set `online = True` (keep `name`); else insert `User { identity = ctx.sender, name = Nothing, online = True }`.
  - `client_disconnected`: set that user's `online = False` (no-op if unknown).
  - `init`: no-op.
- The field names are already clean single words (`identity`, `name`, `online`, `sender`, `sent`, `text`) — **no idiomatic renames needed**; the Haskell record fields use them verbatim, and `deriveApp` maps only the table/reducer *handle* names to snake_case (`set_name`, `send_message`, `client_connected`, `client_disconnected`).
- The client is env-driven (`VITE_SPACETIMEDB_HOST` default `ws://localhost:3000`, `VITE_SPACETIMEDB_DB_NAME` default `quickstart-chat`) and uses only `user.{identity,name,online}`, `message.{sender,sent,text}`, `reducers.{setName,sendMessage}` — so **no client source changes** beyond deleting the bundled TS server and repointing scripts.
- The GHC-wasm→SpacetimeDB pipeline is proven (phase0 GO-NO-GO): build (`wasm32-wasi-ghc` + `cbits/spacetime_abi.c`) → `wizer` snapshot → stub WASI imports → `spacetime publish -b <wasm>`. Schema accepted; reducer round-trip PASS. The phase0 scripts live at `phase0/scripts/{build-module,wizer-init,stub-wasi,check-imports,live-check}.sh` and are parameterized here for chat.
- `spacetime generate --lang typescript -b/--bin-path <wasm> --out-dir <dir>` and `spacetime publish -b <wasm> quickstart-chat --server local` are both supported (verified via `--help`); `quickstart-chat` matches the db-name regex `/^[a-z0-9]+(-[a-z0-9]+)*$/`.

---

## File Structure

**Create (server):**
- `examples/quickstart-chat/server/chat-module.cabal` — the example package: a `chat-core` library (native, exposes `Chat`), a `chat-module` wasm executable (behind a `wasm` flag), and a `chat-module-test` hspec suite. Depends on `hs-spacetime`.
- `examples/quickstart-chat/server/src/Chat.hs` — `User`/`Message` rows, `App`, handlers, and `chatModule :: ModuleDef`. **No** foreign exports (native-buildable, unit-testable).
- `examples/quickstart-chat/server/app/ChatModule.hs` — thin wasm wrapper: `foreign export ccall` `hs_describe`/`hs_call_reducer` over `Chat.chatModule` (mirrors `server/example/WidgetModule.hs`).
- `examples/quickstart-chat/server/cbits/spacetime_abi.c` — copied from the phase0 module (the ABI shim the wasm exe links).
- `examples/quickstart-chat/server/test/Spec.hs` + `test/ChatSpec.hs` — hermetic reducer/lifecycle tests via an in-memory fake backend.
- `examples/quickstart-chat/server/test/FakeBackend.hs` — a stateful in-memory `Backend` (IORef of tableId→rows) supporting `insert`/`scan`/`delete`, for testing stateful handlers.
- `examples/quickstart-chat/server/scripts/{build,wizen,stub-wasi,check-imports}.sh` — chat-parameterized copies of the phase0 wasm pipeline.

**Create (client):**
- `examples/quickstart-chat/client-web/**` — the `chat-react-ts` template vendored, minus `spacetimedb/` (bundled TS server) and `.template.json`, with `package.json` scripts/deps repointed. `src/module_bindings/**` is regenerated in Group D.

**Create (integration + docs):**
- `examples/quickstart-chat/scripts/live-e2e.sh` — boot local server, publish the chat wasm, call reducers, assert rows (gated).
- `examples/quickstart-chat/README.md` — end-to-end walkthrough.
- `test/SpacetimeDB/Live/ChatLiveSpec.hs` *(optional Group D2)* — Haskell-side live assertions if we prefer them over the shell script.

**Modify:**
- `cabal.project` — add `examples/quickstart-chat/server` to `packages:`.

No `flake.nix`, `hs-spacetime.cabal`, or main-`test/` change is required (the example is a separate cabal package).

---

## Group A — Chat module (native, TDD)

### Task A1: Scaffold the example cabal package + red test

**Files:**
- Create: `examples/quickstart-chat/server/chat-module.cabal`
- Create: `examples/quickstart-chat/server/src/Chat.hs`
- Create: `examples/quickstart-chat/server/test/Spec.hs`
- Create: `examples/quickstart-chat/server/test/ChatSpec.hs`
- Modify: `cabal.project`

- [ ] **Step 1: Add the package to `cabal.project`**

Append to `cabal.project` (keep existing entries):
```
packages: examples/quickstart-chat/server
```

- [ ] **Step 2: Write `chat-module.cabal`**

```cabal
cabal-version:      3.0
name:               chat-module
version:            0.1.0.0
build-type:         Simple

flag wasm
  description: Build the wasm reactor executable (requires the .#wasm toolchain).
  default:     False
  manual:      True

common warnings
  ghc-options: -Wall

library
  import:           warnings
  hs-source-dirs:   src
  exposed-modules:  Chat
  build-depends:    base, text, hs-spacetime
  default-language: GHC2021
  default-extensions:
    DataKinds DeriveAnyClass DeriveGeneric DerivingStrategies
    DuplicateRecordFields FlexibleInstances OverloadedRecordDot
    OverloadedStrings StandaloneDeriving TypeFamilies NoFieldSelectors

test-suite chat-module-test
  import:           warnings
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Spec.hs
  other-modules:    ChatSpec FakeBackend
  build-depends:    base, text, bytestring, hs-spacetime, chat-module, hspec
  build-tool-depends: hspec-discover:hspec-discover
  default-language: GHC2021
  default-extensions:
    DataKinds DeriveAnyClass DeriveGeneric DerivingStrategies
    DuplicateRecordFields FlexibleInstances OverloadedRecordDot
    OverloadedStrings StandaloneDeriving TypeApplications NoFieldSelectors

executable chat-module
  import:           warnings
  if !flag(wasm)
    buildable: False
  hs-source-dirs:   app
  main-is:          ChatModule.hs
  c-sources:        cbits/spacetime_abi.c
  build-depends:    base, text, hs-spacetime, chat-module
  ghc-options:      -no-hs-main -optl-mexec-model=reactor
                    "-optl-Wl,--export=__describe_module__,--export=__call_reducer__"
  default-language: GHC2021
```

> Note: mirror the exact `ghc-options`/exports from `server/example/WidgetModule.hs`'s stanza in `hs-spacetime.cabal` if they differ from the above; that stanza is the source of truth for the wasm link flags. (Read it first: `hs-spacetime.cabal` around the `widget-module-example` executable.)

- [ ] **Step 3: Stub `src/Chat.hs`**

```haskell
module Chat (chatModule) where

import SpacetimeDB.Server (ModuleDef)

chatModule :: ModuleDef
chatModule = error "not implemented"
```

- [ ] **Step 4: Test harness files**

`test/Spec.hs`:
```haskell
{-# OPTIONS_GHC -F -pgmF hspec-discover #-}
```

`test/ChatSpec.hs` (first failing assertion — the module has both tables):
```haskell
module ChatSpec (spec) where

import SpacetimeDB.Server (moduleTableNames)   -- see Step 6 note
import Chat (chatModule)
import Test.Hspec

spec :: Spec
spec = describe "Chat.chatModule" $
  it "declares the user and message tables" $
    moduleTableNames chatModule `shouldContain` ["user", "message"]
```

- [ ] **Step 5: Run to verify it fails**

Run: `nix develop .#dev --command cabal build chat-module`
Expected: FAIL (either `not implemented` at eval or a missing-accessor compile error) — confirms the package wires up and the test targets real behavior.

- [ ] **Step 6: Resolve the schema-introspection accessor**

`moduleTableNames` may not exist yet. Inspect `SpacetimeDB.Server`/`Server.Schema` for the accessor that lists a `ModuleDef`'s table names (likely via its `ModuleSchema`/`tables`). If none is exported, define a tiny local helper in `ChatSpec` that reads the module's schema (e.g. `map (.name) . (.tables)` over the derived `ModuleSchema`), rather than adding to the library. Keep the test intent: assert `user` and `message` are present.

Run: `nix develop .#dev --command cabal build chat-module-test 2>&1 | tail -20`
Expected: compiles once the accessor is resolved; the test itself still FAILS because `chatModule = error …`.

- [ ] **Step 7: Commit**

```bash
git add cabal.project examples/quickstart-chat/server
git commit -m "test(chat): scaffold chat-module package + failing table test

<trailers>"
```

### Task A2: `User`/`Message` rows + `App` + names

**Files:**
- Modify: `examples/quickstart-chat/server/src/Chat.hs`
- Test: `examples/quickstart-chat/server/test/ChatSpec.hs`

- [ ] **Step 1: Add the failing name test**

Append to `ChatSpec`:
```haskell
  it "derives snake_case reducer + lifecycle handles" $ do
    -- reducerNames/lifecycle accessors mirror those used in DeriveSpec;
    -- resolve exact names from SpacetimeDB.Server as in A1 Step 6.
    moduleReducerNames chatModule `shouldContain` ["set_name", "send_message"]
```

- [ ] **Step 2: Verify it fails** — `nix develop .#dev --command cabal test chat-module-test 2>&1 | tail -20` → FAIL.

- [ ] **Step 3: Implement rows + App (no handlers yet)**

Replace `src/Chat.hs` body (keep `chatModule` erroring until A6):
```haskell
module Chat (User (..), Message (..), SetNameArgs (..), SendMessageArgs (..), App (..), app, chatModule) where

import Data.Text (Text)
import GHC.Generics (Generic)
import SpacetimeDB.Server

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

newtype SetNameArgs = SetNameArgs {name :: Text}
  deriving stock (Generic) deriving anyclass (SpacetimeType)
newtype SendMessageArgs = SendMessageArgs {text :: Text}
  deriving stock (Generic) deriving anyclass (SpacetimeType)

data App = App
  { user               :: Table User
  , message            :: Table Message
  , setName            :: Reducer SetNameArgs
  , sendMessage        :: Reducer SendMessageArgs
  , init               :: LifecycleHook 'Init
  , clientConnected    :: LifecycleHook 'OnConnect
  , clientDisconnected :: LifecycleHook 'OnDisconnect
  }
  deriving stock (Generic)

app :: App
app = deriveApp

chatModule :: ModuleDef
chatModule = error "not implemented"
```

> `Identity`, `Timestamp`, `Column`, `Table`, `Reducer`, `LifecycleHook`, `SpacetimeType`, `deriveApp`, `View('Value)`, `ColAttr('Pk)`, `Lifecycle('Init/'OnConnect/'OnDisconnect)` all come from `SpacetimeDB.Server`. Confirm the re-export surface (it re-exports `SpacetimeDB.Server.*`); add explicit imports if any symbol isn't re-exported.

- [ ] **Step 4: Run** — the A1 table test now needs `chatModule` non-erroring for introspection. If `moduleTableNames`/`moduleReducerNames` force evaluation of `chatModule`, temporarily derive names from `app`/the `App` type instead (they don't need handlers). Adjust the two tests to introspect `deriveModule app <stub handlers>` built inline, OR defer both name assertions to A6 when `chatModule` exists. **Decision:** move the two name tests to A6; in A2 assert only that `app` builds:
```haskell
  it "derives table/reducer handle names on app" $ do
    tableName app.user `shouldBe` "user"
    tableName app.message `shouldBe` "message"
    reducerName app.setName `shouldBe` "set_name"
    reducerName app.sendMessage `shouldBe` "send_message"
    lifecycleHookName app.clientConnected `shouldBe` "client_connected"
```
Run: `nix develop .#dev --command cabal test chat-module-test 2>&1 | tail -20` → PASS.

- [ ] **Step 5: Format + commit**
```bash
nix develop .#dev --command fourmolu -i examples/quickstart-chat/server/src/Chat.hs examples/quickstart-chat/server/test/ChatSpec.hs
git add examples/quickstart-chat/server
git commit -m "feat(chat): User/Message rows + App with derived handle names

<trailers>"
```

### Task A3: In-memory fake backend + `send_message`

**Files:**
- Create: `examples/quickstart-chat/server/test/FakeBackend.hs`
- Modify: `examples/quickstart-chat/server/src/Chat.hs`, `test/ChatSpec.hs`

- [ ] **Step 1: Build the fake backend**

`test/FakeBackend.hs` — a stateful `Backend` backed by an `IORef (Map Word32 [ByteString])` (tableId → row-bytes). Model on `DeriveSpec`'s inline `Backend` but add real `scan`/`delete`:
```haskell
module FakeBackend (newFake, fakeBackend, dumpTable) where

import Data.IORef
import qualified Data.Map.Strict as M
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word32)
import SpacetimeDB.Server.Internal (Backend (..), TableId (..))

-- tableId is assigned per table name deterministically (name -> id) so the
-- module's `tableId` lookups resolve; store rows as a concatenation the module's
-- `scan` decoder expects (match the shape `scanRows` decodes — a length-prefixed
-- or newline-delimited row list; confirm against Server.Table.scanRows).
newFake :: [(BS.ByteString, Word32)] -> IO (IORef (M.Map Word32 [ByteString]))
newFake _ = newIORef M.empty

fakeBackend :: (BS.ByteString -> Maybe Word32) -> IORef (M.Map Word32 [ByteString]) -> Backend
fakeBackend nameToId ref = Backend
  { tableId = \nm -> pure (maybe (Left "unknown table") (Right . TableId) (nameToId nm))
  , insert  = \(TableId t) row -> modifyIORef' ref (M.insertWith (flip (++)) t [row]) >> pure (Right ())
  , scan    = \(TableId t) -> Right . encodeRows . M.findWithDefault [] t <$> readIORef ref
  , delete  = \(TableId t) row -> modifyIORef' ref (M.adjust (filter (/= row)) t) >> pure (Right ())
  , log     = \_ -> pure ()
  }

dumpTable :: IORef (M.Map Word32 [ByteString]) -> Word32 -> IO [ByteString]
dumpTable ref t = M.findWithDefault [] t <$> readIORef ref
```
> **Resolve the row-list wire shape** for `scan`/`encodeRows` by reading `SpacetimeDB.Server.Table.scanRows` and `Dispatch`/`ABI` (how the real host returns scanned rows — the exact framing `scanRows` decodes). `encodeRows` must produce exactly that. Keep this the *only* place the fake touches wire framing.

- [ ] **Step 2: Failing `send_message` test**
```haskell
  it "send_message inserts one Message with sender+timestamp" $ do
    ref <- newIORef M.empty
    let be = fakeBackend nameToId ref
        args = runEncoder encodeVal (SendMessageArgs "hi")
    r <- dispatchReducer chatModule (reducerIndex "send_message") (mkContext 0 0 0 0 0 0 7) args be
    r `shouldBe` Right ()
    rows <- dumpTable ref (tableIdOf "message")
    length rows `shouldBe` 1
```
> `reducerIndex`, `tableIdOf`, `nameToId`, and `mkContext`'s arg order come from the existing dispatch tests (`DeriveSpec`, `DispatchSpec`). `mkContext`'s timestamp/sender params: reuse the signature `DispatchSpec` uses. Resolve exact indices from `App` field order (`set_name`=0, `send_message`=1, then lifecycle).

- [ ] **Step 3: Run → FAIL** (`chatModule` still errors): `nix develop .#dev --command cabal test chat-module-test 2>&1 | tail -20`.

- [ ] **Step 4: Implement `send_message` + wire `chatModule` (handlers stubbed except send)**

In `Chat.hs`, add handlers record + `chatModule`:
```haskell
import SpacetimeDB.Server (ReducerM, ask, throwError, insertRow, deleteRow, scanRows, deriveModule)
import qualified Data.Text as T

data Handlers = Handlers
  { setName            :: SetNameArgs -> ReducerM ()
  , sendMessage        :: SendMessageArgs -> ReducerM ()
  , init               :: () -> ReducerM ()
  , clientConnected    :: () -> ReducerM ()
  , clientDisconnected :: () -> ReducerM ()
  }
  deriving stock (Generic)

chatModule :: ModuleDef
chatModule = deriveModule app Handlers
  { setName            = \_ -> pure ()   -- A4
  , sendMessage        = \(SendMessageArgs t) -> do
      ctx <- ask
      if T.null t then throwError "Messages must not be empty"
                  else insertRow app.message (Message ctx.sender ctx.timestamp t)
  , init               = \() -> pure ()
  , clientConnected    = \() -> pure ()          -- A5
  , clientDisconnected = \() -> pure ()          -- A5
  }
```
> Confirm `ReducerContext` field names (`sender`, `timestamp`) from `SpacetimeDB.Server.Types`/`Dispatch` (PersonModule uses `ctx.timestamp`; DispatchSpec covers `ctx.sender`/`ctx.connectionId`).

- [ ] **Step 5: Run → PASS.** Also add the empty-text case:
```haskell
  it "send_message rejects empty text" $ do
    ref <- newIORef M.empty
    r <- dispatchReducer chatModule (reducerIndex "send_message")
           (mkContext 0 0 0 0 0 0 7) (runEncoder encodeVal (SendMessageArgs "")) (fakeBackend nameToId ref)
    r `shouldBe` Left "Messages must not be empty"
```
Run → PASS.

- [ ] **Step 6: Format + commit**
```bash
nix develop .#dev --command fourmolu -i examples/quickstart-chat/server/src/Chat.hs examples/quickstart-chat/server/test/ChatSpec.hs examples/quickstart-chat/server/test/FakeBackend.hs
git add examples/quickstart-chat/server
git commit -m "feat(chat): send_message inserts Message; empty text rejected

<trailers>"
```

### Task A4: `set_name`

**Files:** Modify `src/Chat.hs`, `test/ChatSpec.hs`.

- [ ] **Step 1: Failing tests** — unknown-user error, then successful rename:
```haskell
  it "set_name errors for an unknown user" $ do
    ref <- newIORef M.empty
    r <- dispatchReducer chatModule (reducerIndex "set_name")
           (mkContext 0 0 0 0 0 0 0) (runEncoder encodeVal (SetNameArgs "alice")) (fakeBackend nameToId ref)
    r `shouldBe` Left "Cannot set name for unknown user"

  it "set_name updates an existing user's name" $ do
    ref <- newIORef M.empty
    -- seed a user for sender=identityFromInteger 0 via client_connected first:
    _ <- dispatchReducer chatModule (reducerIndex "client_connected") (mkContext 0 0 0 0 0 0 0) mempty (fakeBackend nameToId ref)
    r <- dispatchReducer chatModule (reducerIndex "set_name")
           (mkContext 0 0 0 0 0 0 0) (runEncoder encodeVal (SetNameArgs "alice")) (fakeBackend nameToId ref)
    r `shouldBe` Right ()
    [row] <- dumpTable ref (tableIdOf "user")
    (runExact (decodeVal @(User 'Value)) row) `shouldBe` Right (User (identityFromInteger 0) (Just "alice") True)
```
> `set_name` reads the sender from context (`mkContext … sender …`); use the same context sender for connect + set. `client_connected` (A5) must exist for the seed; if implementing A4 before A5, seed by direct `insert` on the fake instead. Recommended order: do A5 before A4's success test, or seed manually.

- [ ] **Step 2: Verify FAIL.**

- [ ] **Step 3: Implement `set_name`**
```haskell
  , setName = \(SetNameArgs n) -> do
      ctx <- ask
      if T.null n then throwError "Names must not be empty" else do
        users <- scanRows app.user
        case filter ((== ctx.sender) . (.identity)) users of
          (u : _) -> do
            deleteRow app.user u
            insertRow app.user u { name = Just n }
          [] -> throwError "Cannot set name for unknown user"
```
> Update-by-Pk = delete + re-insert (no update primitive; see spec "Upsert detail"). Confirm record-update syntax works under `NoFieldSelectors` (it does for construction/update).

- [ ] **Step 4: Verify PASS. Step 5: Format + commit** (`feat(chat): set_name updates the sender's user; unknown-user + empty rejected`).

### Task A5: Lifecycle (`init`, `client_connected`, `client_disconnected`)

**Files:** Modify `src/Chat.hs`, `test/ChatSpec.hs`.

- [ ] **Step 1: Failing tests**
```haskell
  it "client_connected inserts a new online user" $ do
    ref <- newIORef M.empty
    _ <- dispatchReducer chatModule (reducerIndex "client_connected") (mkContext 0 0 0 0 0 0 0) mempty (fakeBackend nameToId ref)
    [row] <- dumpTable ref (tableIdOf "user")
    runExact (decodeVal @(User 'Value)) row `shouldBe` Right (User (identityFromInteger 0) Nothing True)

  it "client_connected re-marks a returning user online, keeping name" $ do
    ref <- newIORef M.empty
    _ <- dispatchReducer chatModule (reducerIndex "client_connected") (mkContext 0 0 0 0 0 0 0) mempty (fakeBackend nameToId ref)
    _ <- dispatchReducer chatModule (reducerIndex "set_name") (mkContext 0 0 0 0 0 0 0) (runEncoder encodeVal (SetNameArgs "bob")) (fakeBackend nameToId ref)
    _ <- dispatchReducer chatModule (reducerIndex "client_disconnected") (mkContext 0 0 0 0 0 0 0) mempty (fakeBackend nameToId ref)
    _ <- dispatchReducer chatModule (reducerIndex "client_connected") (mkContext 0 0 0 0 0 0 0) mempty (fakeBackend nameToId ref)
    [row] <- dumpTable ref (tableIdOf "user")
    runExact (decodeVal @(User 'Value)) row `shouldBe` Right (User (identityFromInteger 0) (Just "bob") True)

  it "client_disconnected marks the user offline" $ do
    ref <- newIORef M.empty
    _ <- dispatchReducer chatModule (reducerIndex "client_connected") (mkContext 0 0 0 0 0 0 0) mempty (fakeBackend nameToId ref)
    _ <- dispatchReducer chatModule (reducerIndex "client_disconnected") (mkContext 0 0 0 0 0 0 0) mempty (fakeBackend nameToId ref)
    [row] <- dumpTable ref (tableIdOf "user")
    runExact (decodeVal @(User 'Value)) row `shouldBe` Right (User (identityFromInteger 0) Nothing False)
```

- [ ] **Step 2: Verify FAIL.**

- [ ] **Step 3: Implement** (factor an `upsertOnline` helper):
```haskell
  , init            = \() -> pure ()
  , clientConnected = \() -> setOnline True
  , clientDisconnected = \() -> setOnline False
```
with, in `Chat.hs`:
```haskell
setOnline :: Bool -> ReducerM ()
setOnline flag = do
  ctx <- ask
  users <- scanRows app.user
  case filter ((== ctx.sender) . (.identity)) users of
    (u : _) -> deleteRow app.user u >> insertRow app.user u { online = flag }
    []      -> if flag
                 then insertRow app.user (User ctx.sender Nothing True)
                 else pure ()
```

- [ ] **Step 4: Verify PASS. Step 5: Format + commit** (`feat(chat): lifecycle connect/disconnect presence; init no-op`).

### Task A6: Module-level assertions + full green

**Files:** Modify `test/ChatSpec.hs`.

- [ ] **Step 1:** Add the deferred name/shape assertions now that `chatModule` is real:
```haskell
  it "declares user+message tables and set_name/send_message reducers" $ do
    moduleTableNames chatModule   `shouldMatchList` ["user", "message"]
    moduleReducerNames chatModule `shouldContain`   ["set_name", "send_message"]
```
- [ ] **Step 2: Run whole example suite** — `nix develop .#dev --command cabal test chat-module-test 2>&1 | tail -20` → all PASS.
- [ ] **Step 3:** Confirm the main suite is untouched — `nix develop .#dev --command cabal test hs-spacetime-test 2>&1 | tail -3` → still 113/0.
- [ ] **Step 4: Format + commit** (`test(chat): module-level table/reducer assertions; suite green`).

---

## Group B — Wasm build pipeline (gated on `.#wasm`)

### Task B1: Wasm wrapper + ABI shim + build scripts

**Files:**
- Create: `examples/quickstart-chat/server/app/ChatModule.hs`
- Create: `examples/quickstart-chat/server/cbits/spacetime_abi.c` (copy from `phase0/module/cbits/spacetime_abi.c`)
- Create: `examples/quickstart-chat/server/scripts/{build,wizen,stub-wasi,check-imports}.sh` (chat-parameterized copies of `phase0/scripts/*`)

- [ ] **Step 1: Wasm wrapper** — mirror `server/example/WidgetModule.hs`'s export block exactly, over `Chat.chatModule`:
```haskell
module Main where

import Data.Word (Word16, Word32, Word64)
import Chat (chatModule)
import SpacetimeDB.Server.ABI (runDescribe, runCallReducer)

foreign export ccall hs_describe :: Word32 -> IO ()
hs_describe :: Word32 -> IO ()
hs_describe = runDescribe chatModule

foreign export ccall
  hs_call_reducer
    :: Word32 -> Word64 -> Word64 -> Word64 -> Word64
    -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> IO Int16
hs_call_reducer = runCallReducer chatModule
```
> Copy the exact `foreign export`/type signature from `WidgetModule.hs` — do not hand-edit the ABI arity.

- [ ] **Step 2: Copy the ABI C shim + pipeline scripts.** Copy `phase0/module/cbits/spacetime_abi.c` and `phase0/scripts/{build-module,wizer-init,stub-wasi,check-imports}.sh`, changing only the module name/paths (`person-module` → `chat-module`, output under `examples/quickstart-chat/server/dist/`). Keep the pipeline identical: `build → wizen → stub-wasi`.

- [ ] **Step 3: Build the wasm**

Run:
```bash
nix develop .#wasm --command bash examples/quickstart-chat/server/scripts/build.sh
nix develop .#wasm --command bash examples/quickstart-chat/server/scripts/wizen.sh
nix develop .#wasm --command bash examples/quickstart-chat/server/scripts/stub-wasi.sh
```
Expected: produces `examples/quickstart-chat/server/dist/chat-module.nowasi.wasm`.

- [ ] **Step 4: Verify zero WASI imports** — `nix develop .#wasm --command bash examples/quickstart-chat/server/scripts/check-imports.sh` → prints only the SpacetimeDB host imports + the two exports (`__describe_module__`, `__call_reducer__`); **no** `wasi_snapshot_preview1` imports. (Same acceptance as phase0 GO-NO-GO.)

- [ ] **Step 5: Commit** (`build(chat): wasm reactor wrapper + phase0 build pipeline`). Do **not** commit the `.wasm` artifact (gitignore `examples/quickstart-chat/server/dist/`).

---

## Group C — Web client from the `chat-react-ts` template (mechanical, parallel)

### Task C1: Vendor the template, strip the TS server, repoint scripts

**Files:** Create `examples/quickstart-chat/client-web/**` from the pinned template; modify `package.json`.

- [ ] **Step 1: Copy the template in**

The pinned template lives in the nix store at the path printed by:
```bash
nix flake prefetch --json github:clockworklabs/SpacetimeDB/b42765a099f407e75f045f6a7d973d2cea0d278e | \
  python3 -c "import json,sys;print(json.load(sys.stdin)['storePath'])"
```
Copy `<storePath>/templates/chat-react-ts/` → `examples/quickstart-chat/client-web/`, then remove the vendored server + template metadata:
```bash
rm -rf examples/quickstart-chat/client-web/spacetimedb
rm -f  examples/quickstart-chat/client-web/.template.json
```

- [ ] **Step 2: Repoint `package.json`**

- Replace `"spacetimedb": "workspace:*"` with the published version matching rev `b42765a`. Resolve it:
  ```bash
  nix develop .#live --command npm view spacetimedb version    # or check the SpacetimeDB release for b42765a
  ```
  Pin that exact version (e.g. `"spacetimedb": "1.x.y"`).
- Replace the module scripts (they referenced the deleted TS server / monorepo `gen-bindings`) with wasm-based ones:
  ```json
  "spacetime:generate": "spacetime generate --lang typescript --out-dir src/module_bindings --bin-path ../server/dist/chat-module.nowasi.wasm && prettier --write src/module_bindings",
  "spacetime:publish:local": "spacetime publish -b ../server/dist/chat-module.nowasi.wasm quickstart-chat --server local"
  ```
  Remove the old `"generate"` (cargo `gen-bindings`) and `"spacetime:publish"` (maincloud) scripts, or keep the latter repointed at `-b`.

- [ ] **Step 3: `npm install`** (in `.#live`, which has Node):
```bash
nix develop .#live --command bash -c "cd examples/quickstart-chat/client-web && npm install"
```
Expected: resolves `spacetimedb`, react, vite; no `workspace:*` error.

- [ ] **Step 4: Type-check the client against the *template's* committed bindings** (still the upstream ones at this point):
```bash
nix develop .#live --command bash -c "cd examples/quickstart-chat/client-web && npx tsc -b --noEmit"
```
Expected: PASS (the template is internally consistent). This baselines the client before we regenerate bindings in Group D.

- [ ] **Step 5: Commit** (`feat(chat): vendor chat-react-ts client; strip TS server; repoint scripts`). Gitignore `node_modules/`, `dist/`.

---

## Group D — Live wiring: publish, generate, verify (gated `SPACETIMEDB_INTEGRATION=1`)

### Task D1: Publish the chat wasm to a local server

**Files:** Create `examples/quickstart-chat/scripts/live-e2e.sh` (model on `phase0/scripts/live-check.sh` + `scripts/live-harness.sh`).

- [ ] **Step 1:** Script boots a throwaway local server (reuse `scripts/live-harness.sh serve` machinery), then:
```bash
spacetime publish -b examples/quickstart-chat/server/dist/chat-module.nowasi.wasm quickstart-chat --server "http://127.0.0.1:$PORT" --anonymous -y
```
- [ ] **Step 2: Run** (`.#live` + prebuilt wasm from Group B):
```bash
SPACETIMEDB_INTEGRATION=1 nix develop .#live --command bash examples/quickstart-chat/scripts/live-e2e.sh publish
```
Expected: `spacetime publish` accepts the schema (as phase0 proved for person-module); prints the db identity.

### Task D2: Drive reducers, assert rows

- [ ] **Step 1:** In `live-e2e.sh`, after publish:
```bash
spacetime call quickstart-chat send_message '["hello from haskell"]' --server "$SRV"
spacetime sql  quickstart-chat "SELECT text FROM message" --server "$SRV"
```
- [ ] **Step 2: Assert** the SQL output contains `hello from haskell`. For `set_name`, first trigger a connection (the CLI identity connects on call) then:
```bash
spacetime call quickstart-chat set_name '["alice"]' --server "$SRV"
spacetime sql  quickstart-chat "SELECT name, online FROM user" --server "$SRV"   # expect alice / true
```
- [ ] **Step 3: Run the gated E2E** → assertions PASS. Wire this as the script's exit code so CI (when `SPACETIMEDB_INTEGRATION=1`) gates on it.

### Task D3: Generate TS bindings from the wasm and diff against upstream

- [ ] **Step 1:** Generate into the client:
```bash
nix develop .#live --command bash -c "cd examples/quickstart-chat/client-web && npm run spacetime:generate"
```
- [ ] **Step 2: Diff** the regenerated `src/module_bindings/` against the upstream template's committed bindings (captured before regeneration). Expected: **byte-identical or trivially different** (the schema mirrors the reference). Investigate any structural difference — a real diff means our derived schema diverges from the reference (field name/order/type), which is a chat-module bug to fix in Group A, not a binding to hand-edit.
- [ ] **Step 3:** Type-check + client tests against the regenerated bindings:
```bash
nix develop .#live --command bash -c "cd examples/quickstart-chat/client-web && npx tsc -b --noEmit && npm test"
```
Expected: PASS (`src/App.integration.test.tsx` is the template's own vitest suite).
- [ ] **Step 4: Commit** the regenerated bindings (`feat(chat): generated TS bindings from the Haskell wasm module`).

### Task D4 (optional): Typed Haskell client round-trip

- [ ] **Step 1:** `examples/quickstart-chat/client-hs/Main.hs` using `SpacetimeDB.Client.Typed` (`callTyped`/`subscribeTable`) against the published `quickstart-chat`: subscribe to `message`, `callTyped app.sendMessage (SendMessageArgs "hi-hs")`, assert the row arrives on the subscription. Add a `chat-client` executable to `chat-module.cabal`.
- [ ] **Step 2:** Gated run under `.#live`; assert round-trip. Commit.

> Reuse the exact `Client.Typed` connection setup from `test/SpacetimeDB/Client/*Spec.hs` and the `app` value from `Chat` (same handles the server derives).

---

## Group E — End-to-end + docs

### Task E1: Manual UI smoke

- [ ] **Step 1:** With the local server running (Group D1) and bindings generated (D3):
```bash
nix develop .#live --command bash -c "cd examples/quickstart-chat/client-web && npm run dev"
```
- [ ] **Step 2:** Open the printed URL. Smoke checklist (record pass/fail in the README):
  1. Page connects (`Connecting…` → chat UI). 2. Set a name; it appears under Profile. 3. Send a message; it appears in Messages with your name. 4. Open a second browser/incognito tab → both appear under **Online**; closing one moves it to **Offline** (presence via `client_connected`/`client_disconnected`).

### Task E2: README walkthrough

- [ ] **Step 1:** Write `examples/quickstart-chat/README.md`: what it demonstrates (a full SpacetimeDB app authored in Haskell), the layout, and the exact command sequence — build wasm (`.#wasm`), publish (`.#live`), generate bindings, run the client — plus the smoke checklist and a note that the client is the upstream template unmodified except for deleting the TS server and repointing scripts.
- [ ] **Step 2: Commit** (`docs(chat): end-to-end README walkthrough`).

---

## Self-Review Notes (author)

- **Spec coverage:** module + hermetic tests (Group A), wasm buildable (Group B), live publish + reducer effects (Group D1–D2), typed Haskell client round-trip (Group D4), TS bindings + web UI E2E (Groups C, D3, E). The spec's "proof by live round trip" is Groups D–E; the "no Rust chat oracle" decision is honored (D3 diffs against the *upstream template bindings*, not a Rust golden).
- **Parallelism:** Groups A/B (server) and C (client) are independent until Group D; C1 Step 4 type-checks the client against the upstream bindings before D3 regenerates them, so the client track is verifiable on its own.
- **Placeholder honesty:** three values are resolved by an explicit command rather than hard-coded, because they are environment-derived, not guessable: the schema-introspection accessor names (A1 Step 6 — resolved from `SpacetimeDB.Server`), the `scan` row-list wire framing (A3 Step 1 — resolved from `Server.Table.scanRows`), and the published `spacetimedb` npm version (C1 Step 2 — resolved from `npm view`). Each step names the exact source to read; none is left as "TBD".
- **Type consistency:** `App`/`Handlers` field order fixes reducer ids (`set_name`=0, `send_message`=1, `init`=2, `client_connected`=3, `client_disconnected`=4); `reducerIndex` in tests must match. Row types `User`/`Message` and args `SetNameArgs`/`SendMessageArgs` are used identically in `Chat.hs`, the wasm wrapper, and the tests.
- **Nix isolation:** no `flake.nix` / `hs-spacetime.cabal` change; the example is a separate cabal package added only to `cabal.project`; all work on the gitignored worktree branch. One rebuild on eventual merge, as agreed.
- **Ordering caveat (A4/A5):** `set_name`'s success test depends on a seeded user, which `client_connected` (A5) provides — implement A5 before A4's success case, or seed the fake directly. Called out in A4 Step 1.
