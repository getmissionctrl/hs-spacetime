# quickstart-chat Haskell Clients Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two Haskell clients for the `quickstart-chat` example — a native Brick TUI on the existing SDK, and a browser client compiled to wasm where Haskell owns the WebSocket via GHC's JavaScript FFI — both reusing the server module's typed handles.

**Architecture:** Two independent tracks. **Track A (TUI)** is native and depends only on the existing full `hs-spacetime` client library plus `chat-module` + `brick`/`vty`. **Track B (browser)** adds a new wasm-safe sublibrary `spacetime-client-core` (six already-pure modules), then a wasm reactor executable whose Haskell code opens/reads/writes a `WebSocket` through `foreign import javascript` callbacks over a single-threaded `IORef` model — no STM/async, no Promise-await. The two tracks share no build artifacts and run in parallel; the only common input is the `Chat` module's typed handles, which already exist.

**Tech Stack:** GHC 9.10 (native, `.#dev`), GHC 9.12 wasm (`ghc-wasm-meta all_9_12`, `.#wasm`), Brick/Vty, `foreign import javascript` (GHC wasm JSFFI) + `post-link.mjs` + `@bjorn3/browser_wasi_shim`, SpacetimeDB WS protocol `v2.bsatn.spacetimedb`.

---

## B2 CHECKPOINT OUTCOME (2026-09-22): HYBRID chosen

The B2 spike proved: Haskell→wasm builds/boots in-browser, the RTS initializes, and **synchronous JS→Haskell calls via `foreign export javascript` work** (an exported action runs to completion and its WASI-stdout output appears). It also proved the **Pure path is blocked**: a Haskell closure installed as a JS callback via `foreign import javascript "wrapper"` (WebSocket `onopen`/`onmessage`, or even a `setTimeout` handler) **does not fire** in the reactor, even with a live keep-alive thread — a deep GHC-wasm scheduler limitation we could not resolve without browser-console/WASI tooling.

**Decision:** build the browser client in the **Hybrid** shape. **JS owns the WebSocket and its event handlers**; on each event it makes a *synchronous* call into exported Haskell functions (the proven primitive). Haskell/wasm still owns 100% of the SpacetimeDB protocol, BSATN decode, state, and view (`Chat.Web.Core`, unchanged). This changes **B4** (export byte-processing functions instead of Haskell-owned socket + wrapper callbacks) and **B5** (JS `run.mjs` holds the socket and calls the exports). **B3 is unchanged.** Also note the loader fix the spike found: `wasi.initialize(inst)` already calls `_initialize` — do NOT call `_initialize()` again (double-init traps), and cache-bust the `.wasm`/glue fetches.

## Verified Facts (used throughout — do not re-derive)

- **Typed handles** (`examples/quickstart-chat/server/src/Chat.hs`, module `Chat` exports `User(..) Message(..) SetNameArgs(..) SendMessageArgs(..) App(..) app chatModule`):
  ```haskell
  data App = App { user :: Table User, message :: Table Message
                 , setName :: Reducer SetNameArgs, sendMessage :: Reducer SendMessageArgs
                 , init :: LifecycleHook 'Init, clientConnected :: LifecycleHook 'OnConnect
                 , clientDisconnected :: LifecycleHook 'OnDisconnect } deriving stock Generic
  app :: App; app = deriveApp
  data User f = User { identity :: Column f Identity '[ 'Pk], name :: Column f (Maybe Text) '[], online :: Column f Bool '[] }
  data Message f = Message { sender :: Column f Identity '[], sent :: Column f Timestamp '[], text :: Column f Text '[] }
  newtype SetNameArgs = SetNameArgs { name :: Text }        -- SpacetimeType
  newtype SendMessageArgs = SendMessageArgs { text :: Text } -- SpacetimeType
  ```
  `chat-module` uses `NoFieldSelectors`, so **read record fields by pattern-matching** (`User i mn on`, `Message s ts txt`) and **read `App` handles via record-dot** (`app.user`, `app.sendMessage` — works via `HasField`, needs `OverloadedRecordDot`). At `'Value`, `Column f τ attrs` reduces to `τ`, so `User 'Value = User Identity (Maybe Text) Bool` and `Message 'Value = Message Identity Timestamp Text`; both derive `Eq`/`Show`.
- **SDK surface** (native, `SpacetimeDB.Client`): `builder :: Text -> Int -> Text -> Config`; `withCompression :: Compression -> Config -> Config`; `withReconnect :: ReconnectPolicy -> Config -> Config` with `ReconnectPolicy = NoReconnect | Reconnect {initialMs, maxMs, maxAttempts :: Maybe Int}`; `onEvent :: (Event -> IO ()) -> Config -> Config`; `start :: Config -> IO (Either Text Client)`; `stop :: Client -> IO ()`. `SpacetimeDB.Client.Typed`: `callTyped :: SpacetimeType args => Client -> Reducer args -> args -> (ReplyPayload -> IO ()) -> IO ()`; `subscribeTable :: forall (row :: Row). SpacetimeType (row 'Value) => Table row -> Text -> ([row 'Value] -> [row 'Value] -> IO ()) -> Config -> Config`. `SpacetimeDB.Client.Types.formatEvent :: Event -> Text`. `Compression(..) = CompNone | CompBrotli | CompGzip` in `SpacetimeDB.Protocol.Messages`.
- **wasm-safe module set** for `spacetime-client-core` (all confirmed free of `websockets`/`wuss`/`network`/`zlib`/`brotli`/`stm`/`async`): `SpacetimeDB.Protocol.Messages`, `SpacetimeDB.Protocol.RowList`, `SpacetimeDB.Client.State`, `SpacetimeDB.Client.Dispatch`, `SpacetimeDB.Client.Types`, `SpacetimeDB.Client.Endpoint`. `SpacetimeDB.Protocol.Frame` is **excluded** (module-scope brotli/gzip imports).
- **Wire protocol:**
  - Subprotocol header value `v2.bsatn.spacetimedb`. WS URL path (from `Endpoint.subscribeUrl`): `<root>/v1/database/<db>/subscribe?compression=None`, where `<root>` is `http(s)://host:port`; for the browser rewrite the scheme to `ws(s)://`.
  - Client→server frames are **raw** BSATN `ClientMessage` bytes, **no leading tag** (`writerLoop` does `WS.sendBinaryData conn bs`). Encoders (`SpacetimeDB.Protocol.Messages`): `encodeSubscribe :: Word32 -> Word32 -> [Text] -> Builder` (sum tag 0); `encodeCallReducer :: Word32 -> Word8 -> Text -> ByteString -> Builder` (sum tag 3). `encodeClientMessage :: ClientMessage -> Builder`.
  - Server→client frames are `tag :: Word8` ++ payload; with `compression=None` the tag is `0` and payload is raw BSATN `ServerMessage`. Decode payload with `decodeServerMessage :: Decoder ServerMessage`.
  - `ServerMessage = InitialConnection Identity ConnectionId Text | SubscribeApplied Word32 Word32 QueryRows | UnsubscribeApplied … | SubscriptionError … | TransactionUpdate [QuerySetUpdate] | OneOffQueryResult … | ReducerResult Word32 Timestamp ReducerOutcome | ProcedureResult … | Unhandled Word8`. `QueryRows = QueryRows [SingleTableRows]`; `SingleTableRows = SingleTableRows Text [ByteString]`; `QuerySetUpdate = QuerySetUpdate Word32 [TableUpdate]`; `TableUpdate = TableUpdate Text [TableUpdateRows]`; `TableUpdateRows = PersistentTable [ByteString] [ByteString] | EventTable [ByteString]`.
- **BSATN entry points:** `runEncoder :: Encoder a -> a -> ByteString` (`Encoder a = a -> Builder`); `runExact :: Decoder a -> ByteString -> Either DecodeError a`; per-type `encodeVal :: a -> Builder` / `decodeVal :: Decoder a` from `class SpacetimeType`. `reducerName :: Reducer a -> Text` and `tableName :: Table row -> Text` (from `SpacetimeDB.Server.Reducer`/`.Table`). `Identity`/`Timestamp` in `SpacetimeDB.BSATN.Types` (`identityToInteger :: Identity -> Integer`).
- **Build/harness:** root `cabal.project` is `packages: . examples/quickstart-chat/server` with `tests: True`. Server wasm build reference: `examples/quickstart-chat/server/scripts/build-wasm.sh`. Live harness: `scripts/live-harness.sh serve` (used by `test/SpacetimeDB/Live/Harness.hs`); integration tests gate on `SPACETIMEDB_INTEGRATION=1`. Dev shell = `hs-spacetime.env` (GHC carries deps parsed from `hs-spacetime.cabal`).

---

## File Structure

**Track B shared prep (modifies the client package):**
- Modify `hs-spacetime.cabal`: add `library spacetime-client-core` (visibility public; the six wasm-safe modules from `src/`; deps `base bytestring text containers bsatn wide-word`; **no** `if flag(wasm) buildable: False`).

**Track A — TUI (`examples/quickstart-chat/client-tui/`):**
- `chat-tui.cabal` — package `chat-tui`: `library` (pure `Chat.Tui.Model`, `Chat.Tui.Ui`), executable `chat-tui`, test-suite `chat-tui-test`.
- `src/Chat/Tui/Model.hs` — pure chat state + input parsing + rendering (no SDK, no Brick).
- `src/Chat/Tui/Ui.hs` — Brick `App`, draw + event handling over a `UiState` that carries an injected `InputAction -> IO ()` send handler (keeps the SDK out of the UI).
- `app/Main.hs` — SDK wiring: build `Config` (subscriptions → `BChan`), `start`, run `customMain`.
- `test/Spec.hs`, `test/Chat/Tui/ModelSpec.hs` — hermetic unit tests.

**Track B — browser (`examples/quickstart-chat/client-web-hs/`):**
- `chat-web.cabal` — package `chat-web`: `library` (`Chat.Web.Core`), wasm `executable chat-web` behind `flag(wasm)`, test-suite `chat-web-test`.
- `src/Chat/Web/Core.hs` — pure: `decodeFrameNone`, `WebModel`, `applyMessage`, `renderHtml`, outbound byte builders. Depends on `spacetime-client-core` + `chat-module` + `spacetime-server`.
- `src/Chat/Web/Ffi.hs` — `foreign import javascript` bindings (WebSocket open/send, DOM set, console log) + the `IORef` runtime.
- `app/ChatWeb.hs` — reactor entry: `foreign export javascript` `startClient`/`sendMessage`/`setName`.
- `web/index.html`, `web/run.mjs` — host page: `browser_wasi_shim` + generated JSFFI glue + instantiate + drive.
- `scripts/build-web-hs.sh` — wasm build + `post-link.mjs` + assemble `dist/`.
- `spike/` (created in B2, promoted/removed by B4) — minimal JSFFI WebSocket smoke artifact.
- `test/Spec.hs`, `test/Chat/Web/CoreSpec.hs` — hermetic unit tests (native).

**Flake (`flake.nix`):**
- `.#dev`: add `brick`, `vty`, `vty-crossplatform` to the shell's GHC package set (Track A).
- `.#wasm`: add `pkgs.nodejs` (runs `post-link.mjs`) and `pkgs.python3` (static file server for the smoke check) (Track B).

**Root `cabal.project`:** add `examples/quickstart-chat/client-tui` and `examples/quickstart-chat/client-web-hs`.

---

# TRACK A — TUI CLIENT (native)

### Task A1: Flake dep + package scaffold + smoke build

**Files:**
- Modify: `flake.nix`
- Create: `examples/quickstart-chat/client-tui/chat-tui.cabal`
- Create: `examples/quickstart-chat/client-tui/src/Chat/Tui/Model.hs` (stub)
- Modify: `cabal.project`

- [ ] **Step 1: Add brick/vty to the `.#dev` shell**

In `flake.nix`, change the `dev` binding so GHC also carries the TUI libraries. Replace:

```nix
        dev = hs-spacetime.env.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [])
            ++ [ pkgs.cabal-install pkgs.fourmolu pkgs.brotli pkgs.zlib pkgs.pkg-config ];
        });
```

with:

```nix
        # Extra Haskell libs the example clients need but the core package does
        # not depend on (so callCabal2nix does not pull them into GHC's db).
        extraHsPkgs = p: [ p.brick p.vty p.vty-crossplatform ];
        devGhc = pkgs.haskellPackages.ghcWithPackages
          (p: hs-spacetime.getBuildInputs.haskellBuildInputs or [] ++ extraHsPkgs p);
        dev = hs-spacetime.env.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [])
            ++ [ pkgs.cabal-install pkgs.fourmolu pkgs.brotli pkgs.zlib pkgs.pkg-config ]
            ++ extraHsPkgs pkgs.haskellPackages;
        });
```

> Note for the implementer: the goal is only that `brick`, `vty`, `vty-crossplatform` are importable in the `.#dev` GHC. If `hs-spacetime.env` already provides a package db that `overrideAttrs` cannot extend with Haskell libs, instead define `dev` from `pkgs.haskellPackages.shellFor { packages = _: [ hs-spacetime ]; additional = extraHsPkgs; nativeBuildInputs = [ pkgs.cabal-install pkgs.fourmolu pkgs.brotli pkgs.zlib pkgs.pkg-config ]; }`. Verify with Step 4; adjust the nix expression until Step 4 passes.

- [ ] **Step 2: Create the cabal package**

`examples/quickstart-chat/client-tui/chat-tui.cabal`:

```cabal
cabal-version:      3.0
name:               chat-tui
version:            0.1.0.0
synopsis:           quickstart-chat terminal (Brick) client, in Haskell
license:            MIT
build-type:         Simple

common extensions
  default-language:   GHC2021
  default-extensions: DataKinds
                      DuplicateRecordFields
                      LambdaCase
                      OverloadedRecordDot
                      OverloadedStrings
                      TypeApplications
                      NoFieldSelectors

library
  import:           extensions
  hs-source-dirs:   src
  exposed-modules:  Chat.Tui.Model
                    Chat.Tui.Ui
  build-depends:    base
                  , text
                  , containers
                  , brick
                  , vty
                  , hs-spacetime
                  , hs-spacetime:bsatn
                  , hs-spacetime:spacetime-server
                  , chat-module
  ghc-options:      -Wall

executable chat-tui
  import:           extensions
  hs-source-dirs:   app
  main-is:          Main.hs
  build-depends:    base
                  , text
                  , stm
                  , brick
                  , vty
                  , vty-crossplatform
                  , hs-spacetime
                  , chat-module
                  , chat-tui
  ghc-options:      -Wall -threaded

test-suite chat-tui-test
  import:           extensions
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Spec.hs
  other-modules:    Chat.Tui.ModelSpec
  build-depends:    base
                  , text
                  , containers
                  , hs-spacetime:bsatn
                  , hs-spacetime:spacetime-server
                  , chat-module
                  , chat-tui
                  , hspec
  ghc-options:      -Wall
```

- [ ] **Step 3: Stub the library module so the package resolves**

`examples/quickstart-chat/client-tui/src/Chat/Tui/Model.hs`:

```haskell
module Chat.Tui.Model () where
```

- [ ] **Step 4: Wire cabal.project and smoke-build**

Append to `cabal.project`:

```
          examples/quickstart-chat/client-tui
```

Run (in `.#dev`): `cabal build chat-tui:lib:chat-tui`
Expected: configures and builds the stub library (proves `brick`/`vty` resolve). If it fails to find `brick`, fix `flake.nix` (Step 1) and re-enter the shell.

- [ ] **Step 5: Commit**

```bash
git add flake.nix cabal.project examples/quickstart-chat/client-tui/
git commit -m "feat(client-tui): scaffold TUI package + brick/vty in dev shell"
```

---

### Task A2: Pure chat model + tests (TDD)

**Files:**
- Create: `examples/quickstart-chat/client-tui/test/Spec.hs`
- Create: `examples/quickstart-chat/client-tui/test/Chat/Tui/ModelSpec.hs`
- Replace: `examples/quickstart-chat/client-tui/src/Chat/Tui/Model.hs`

- [ ] **Step 1: Write the failing tests**

`examples/quickstart-chat/client-tui/test/Spec.hs`:

```haskell
module Main (main) where

import qualified Chat.Tui.ModelSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec Chat.Tui.ModelSpec.spec
```

`examples/quickstart-chat/client-tui/test/Chat/Tui/ModelSpec.hs`:

```haskell
module Chat.Tui.ModelSpec (spec) where

import qualified Data.Map.Strict as M
import Test.Hspec

import Chat (Message (..), User (..))
import Chat.Tui.Model
import SpacetimeDB.BSATN.Types (Identity, Timestamp (..), identityFromInteger)
import SpacetimeDB.Server.HKD (View (Value))

i1, i2 :: Identity
i1 = identityFromInteger 1
i2 = identityFromInteger 2

spec :: Spec
spec = do
  describe "parseInput" $ do
    it "treats plain text as a message" $
      parseInput "hello" `shouldBe` SendMsg "hello"
    it "treats /name X as a set-name command" $
      parseInput "/name alice" `shouldBe` SetNameCmd "alice"
    it "ignores blank input" $
      parseInput "   " `shouldBe` NoOp
    it "ignores /name with no argument" $
      parseInput "/name   " `shouldBe` NoOp

  describe "name map" $ do
    it "records names from users with a name" $ do
      let s = upsertUsers [User i1 (Just "alice") True] emptyChat
      displayName s i1 `shouldBe` "alice"
    it "falls back to an id prefix when unknown" $
      displayName emptyChat i1 `shouldNotBe` ""
    it "drops names on user removal" $ do
      let s = removeUsers [User i1 (Just "alice") False]
                (upsertUsers [User i1 (Just "alice") True] emptyChat)
      displayName s i1 `shouldNotBe` "alice"

  describe "renderMessage" $
    it "renders as 'name: text' using the name map" $ do
      let s = upsertUsers [User i2 (Just "bob") True] emptyChat
      renderMessage s (Message i2 (Timestamp 0) "hi") `shouldBe` "bob: hi"
```

(`SpacetimeDB.BSATN.Types` exports `Timestamp (..)`, so `Timestamp 0 :: Timestamp` builds a value directly; `renderMessage` ignores the `sent` field anyway.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cabal test chat-tui:chat-tui-test`
Expected: FAIL — `Chat.Tui.Model` does not export `parseInput`, `InputAction`, etc.

- [ ] **Step 3: Implement the model**

Replace `examples/quickstart-chat/client-tui/src/Chat/Tui/Model.hs`:

```haskell
module Chat.Tui.Model
  ( ChatState (..)
  , InputAction (..)
  , emptyChat
  , upsertUsers
  , removeUsers
  , addMessages
  , displayName
  , renderMessage
  , parseInput
  ) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T

import Chat (Message (..), User (..))
import SpacetimeDB.BSATN.Types (Identity, identityToHex)
import SpacetimeDB.Server.HKD (View (Value))

data InputAction = SendMsg Text | SetNameCmd Text | NoOp
  deriving (Eq, Show)

data ChatState = ChatState
  { csNames :: !(Map Identity Text)
  , csMessages :: ![Message 'Value]
  , csInput :: !Text
  , csStatus :: !Text
  }

emptyChat :: ChatState
emptyChat = ChatState M.empty [] "" "connecting…"

upsertUsers :: [User 'Value] -> ChatState -> ChatState
upsertUsers us s = s {csNames = foldr ins (csNames s) us}
 where
  ins (User i mn _) m = case mn of
    Just n | not (T.null n) -> M.insert i n m
    _ -> m

removeUsers :: [User 'Value] -> ChatState -> ChatState
removeUsers us s = s {csNames = foldr (\(User i _ _) -> M.delete i) (csNames s) us}

addMessages :: [Message 'Value] -> ChatState -> ChatState
addMessages ms s = s {csMessages = sortOn sentOf (csMessages s ++ ms)}
 where
  sentOf (Message _ ts _) = ts

displayName :: ChatState -> Identity -> Text
displayName s i = case M.lookup i (csNames s) of
  Just n -> n
  Nothing -> "user-" <> T.take 8 (identityToHex i)

renderMessage :: ChatState -> Message 'Value -> Text
renderMessage s (Message sndr _ txt) = displayName s sndr <> ": " <> txt

parseInput :: Text -> InputAction
parseInput raw = case T.stripPrefix "/name " raw of
  Just rest | not (T.null (T.strip rest)) -> SetNameCmd (T.strip rest)
  _
    | T.null (T.strip raw) -> NoOp
    | otherwise -> SendMsg raw
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal test chat-tui:chat-tui-test`
Expected: PASS (all examples). Fix the `toTs`/`Timestamp` construction per the Step 1 note if the module fails to compile.

- [ ] **Step 5: Commit**

```bash
git add examples/quickstart-chat/client-tui/src/Chat/Tui/Model.hs examples/quickstart-chat/client-tui/test/
git commit -m "feat(client-tui): pure chat model with tests"
```

---

### Task A3: Brick UI module

**Files:**
- Create: `examples/quickstart-chat/client-tui/src/Chat/Tui/Ui.hs`

- [ ] **Step 1: Implement the Brick App over an injected send handler**

`examples/quickstart-chat/client-tui/src/Chat/Tui/Ui.hs`:

```haskell
module Chat.Tui.Ui
  ( Name (..)
  , UiEvent (..)
  , UiState (..)
  , applyEvent
  , chatApp
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (get, modify)
import Data.Text (Text)
import qualified Data.Text as T

import Brick
import Brick.Widgets.Border (borderWithLabel, hBorder)
import qualified Graphics.Vty as V

import Chat (Message, User)
import Chat.Tui.Model
import SpacetimeDB.Server.HKD (View (Value))

data Name = MsgViewport
  deriving (Eq, Ord, Show)

-- | Events pushed onto the Brick channel by the SDK wiring in Main.
data UiEvent
  = EvUsers [User 'Value] [User 'Value] -- inserts, deletes
  | EvMessages [Message 'Value] [Message 'Value]
  | EvStatus Text

data UiState = UiState
  { uiChat :: !ChatState
  , uiSend :: !(InputAction -> IO ()) -- injected by Main; closes over the Client
  }

applyEvent :: UiEvent -> ChatState -> ChatState
applyEvent ev s = case ev of
  EvUsers ins del -> removeUsers del (upsertUsers ins s)
  EvMessages ins _del -> addMessages ins s
  EvStatus t -> s {csStatus = t}

chatApp :: App UiState UiEvent Name
chatApp =
  App
    { appDraw = draw
    , appChooseCursor = showFirstCursor
    , appHandleEvent = handle
    , appStartEvent = pure ()
    , appAttrMap = const (attrMap V.defAttr [])
    }

draw :: UiState -> [Widget Name]
draw st =
  [ vBox
      [ borderWithLabel (str "quickstart-chat (Haskell TUI)") (messages st)
      , hBorder
      , padRight Max (txt ("status: " <> csStatus (uiChat st)))
      , txt ("> " <> csInput (uiChat st))
      ]
  ]

messages :: UiState -> Widget Name
messages st =
  viewport MsgViewport Vertical $
    vBox [txt (renderMessage (uiChat st) m) | m <- csMessages (uiChat st)]

handle :: BrickEvent Name UiEvent -> EventM Name UiState ()
handle = \case
  AppEvent ev -> modify (\s -> s {uiChat = applyEvent ev (uiChat s)})
  VtyEvent (V.EvKey V.KEnter []) -> do
    s <- get
    let action = parseInput (csInput (uiChat s))
    liftIO (uiSend s action)
    modify (\s' -> s' {uiChat = (uiChat s') {csInput = ""}})
  VtyEvent (V.EvKey (V.KChar c) []) ->
    modify (\s -> s {uiChat = (uiChat s) {csInput = csInput (uiChat s) `T.snoc` c}})
  VtyEvent (V.EvKey V.KBS []) ->
    modify (\s -> s {uiChat = (uiChat s) {csInput = dropLast (csInput (uiChat s))}})
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl]) -> halt
  _ -> pure ()
 where
  dropLast t = if T.null t then t else T.init t
```

- [ ] **Step 2: Verify it compiles**

Run: `cabal build chat-tui:lib:chat-tui`
Expected: builds cleanly (no runtime yet). Fix any brick-version signature mismatch (`EventM`, `halt`, `viewport`, `Vertical`, `padRight Max`) against the installed brick; these names are stable in brick ≥ 1.0.

- [ ] **Step 3: Commit**

```bash
git add examples/quickstart-chat/client-tui/src/Chat/Tui/Ui.hs
git commit -m "feat(client-tui): Brick UI (draw + event handling)"
```

---

### Task A4: SDK wiring + main

**Files:**
- Create: `examples/quickstart-chat/client-tui/app/Main.hs`

- [ ] **Step 1: Implement the connect-and-run entrypoint**

`examples/quickstart-chat/client-tui/app/Main.hs`:

```haskell
module Main (main) where

import Control.Monad (void)
import Data.Function ((&))
import qualified Data.Text as T
import System.Environment (lookupEnv)

import Brick (customMain)
import Brick.BChan (BChan, newBChan, writeBChan)
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)

import Chat (app)
import Chat.Tui.Model (InputAction (..), emptyChat)
import Chat.Tui.Ui (UiEvent (..), UiState (..), chatApp)
import SpacetimeDB.Client
import SpacetimeDB.Client.Typed (callTyped, subscribeTable)
import SpacetimeDB.Client.Types (formatEvent)
import SpacetimeDB.Protocol.Messages (Compression (..))

import Chat (SendMessageArgs (..), SetNameArgs (..))

main :: IO ()
main = do
  host <- T.pack . maybe "127.0.0.1" id <$> lookupEnv "STDB_HOST"
  db <- T.pack . maybe "quickstart-chat" id <$> lookupEnv "STDB_DB"
  port <- maybe 3000 read <$> lookupEnv "STDB_PORT"
  chan <- newBChan 64

  let cfg =
        builder host port db
          & withCompression CompNone
          & withReconnect (Reconnect 200 2000 Nothing)
          & subscribeTable app.user (subSql "user") (\ins del -> writeBChan chan (EvUsers ins del))
          & subscribeTable app.message (subSql "message") (\ins del -> writeBChan chan (EvMessages ins del))
          & onEvent (\e -> writeBChan chan (EvStatus (formatEvent e)))

  started <- start cfg
  case started of
    Left err -> putStrLn ("failed to connect: " <> T.unpack err)
    Right client -> do
      let send action = case action of
            SendMsg t -> callTyped client app.sendMessage (SendMessageArgs t) (const (pure ()))
            SetNameCmd n -> callTyped client app.setName (SetNameArgs n) (const (pure ()))
            NoOp -> pure ()
          initial = UiState {uiChat = emptyChat, uiSend = send}
      vty0 <- mkVty V.defaultConfig
      void (customMain vty0 (mkVty V.defaultConfig) (Just chan) chatApp initial)
      stop client
 where
  subSql t = "SELECT * FROM " <> t
```

- [ ] **Step 2: Build the executable**

Run: `cabal build chat-tui:exe:chat-tui`
Expected: builds. Fix minor mismatches (`mkVty`/`defaultConfig` import path is `Graphics.Vty.CrossPlatform`/`Graphics.Vty.Config`; adjust if the installed vty exposes `standardIOConfig`).

- [ ] **Step 3: Commit**

```bash
git add examples/quickstart-chat/client-tui/app/Main.hs
git commit -m "feat(client-tui): SDK wiring + main (connect, subscribe, send)"
```

---

### Task A5: Live e2e (opt-in) + README

**Files:**
- Create: `examples/quickstart-chat/client-tui/README.md`
- Modify: `examples/quickstart-chat/README.md`

- [ ] **Step 1: Document how to run the TUI**

`examples/quickstart-chat/client-tui/README.md`:

```markdown
# quickstart-chat — Haskell TUI client

A terminal chat client (Brick) that connects to the Haskell `quickstart-chat`
module and reuses its typed handles.

## Run

Publish the module (see `../README.md`), start SpacetimeDB on `127.0.0.1:3000`,
then in the `.#dev` shell:

    STDB_HOST=127.0.0.1 STDB_PORT=3000 STDB_DB=quickstart-chat \
      cabal run chat-tui:exe:chat-tui

- Type a line + Enter to send a message.
- `/name alice` + Enter sets your name.
- Esc or Ctrl-C quits.
```

- [ ] **Step 2: Add a manual verification checklist to the example README**

Append a "Haskell TUI client" section to `examples/quickstart-chat/README.md` linking to `client-tui/README.md` and noting the env vars.

- [ ] **Step 3: Manual smoke (documented, not automated)**

With a published module + running server: run two `chat-tui` instances, set a name in one, send a message, confirm it appears in both panes. Record the outcome in the PR description. (No automated headless test for the terminal loop in v1.)

- [ ] **Step 4: Commit**

```bash
git add examples/quickstart-chat/client-tui/README.md examples/quickstart-chat/README.md
git commit -m "docs(client-tui): usage + manual smoke checklist"
```

---

# TRACK B — BROWSER CLIENT (wasm)

### Task B1: `spacetime-client-core` wasm-safe sublibrary

**Files:**
- Modify: `hs-spacetime.cabal`

- [ ] **Step 1: Add the sublibrary stanza**

In `hs-spacetime.cabal`, after the `library spacetime-server` stanza, add:

```cabal
library spacetime-client-core
  import:           warnings
  visibility:       public
  hs-source-dirs:   src
  default-language: Haskell2010
  exposed-modules:  SpacetimeDB.Protocol.Messages
                    SpacetimeDB.Protocol.RowList
                    SpacetimeDB.Client.Endpoint
                    SpacetimeDB.Client.Types
                    SpacetimeDB.Client.State
                    SpacetimeDB.Client.Dispatch
  build-depends:    base >=4.14 && <5
                  , bsatn
                  , bytestring
                  , text
                  , containers
                  , wide-word
```

> This shares `src/` sources with the main `library`; the main library and its `Connection.hs` are unchanged. No `if flag(wasm) buildable: False` — this component builds under both toolchains.

- [ ] **Step 2: Native build**

Run (in `.#dev`): `cabal build hs-spacetime:spacetime-client-core`
Expected: builds the six modules with no `websockets`/`zlib`/`brotli` in the plan.

- [ ] **Step 3: wasm build**

Run (in `.#wasm`): `wasm32-wasi-cabal build -fwasm hs-spacetime:spacetime-client-core`
Expected: builds. If a transitive dep fails to cross-compile, it means a listed module is not as pure as audited — stop and report which import pulled it in.

- [ ] **Step 4: Commit**

```bash
git add hs-spacetime.cabal
git commit -m "feat(client-core): wasm-safe spacetime-client-core sublibrary"
```

---

### Task B2: Browser JSFFI WebSocket spike — CHECKPOINT

**Goal:** prove the browser build+run pipeline and JSFFI callback round-trip in *this* toolchain before building the chat client. This is a throwaway artifact under `client-web-hs/spike/`.

**Files:**
- Modify: `flake.nix` (add `nodejs`, `python3` to `.#wasm`)
- Create: `examples/quickstart-chat/client-web-hs/spike/Spike.hs`
- Create: `examples/quickstart-chat/client-web-hs/spike/spike.cabal`
- Create: `examples/quickstart-chat/client-web-hs/spike/cabal.project`
- Create: `examples/quickstart-chat/client-web-hs/spike/index.html`
- Create: `examples/quickstart-chat/client-web-hs/spike/build.sh`

- [ ] **Step 1: Add node + python to the wasm shell**

In `flake.nix`, extend the `wasm` shell packages:

```nix
        wasm = pkgs.mkShell {
          packages = [
            wasmToolchain
            pkgs.wizer
            pkgs.wasm-tools
            pkgs.binaryen
            pkgs.rustup
            pkgs.cargo
            pkgs.nodejs
            pkgs.python3
            spacetimeCli
          ];
        };
```

- [ ] **Step 2: Minimal JSFFI module that opens a WebSocket from Haskell**

`examples/quickstart-chat/client-web-hs/spike/Spike.hs`:

```haskell
{-# LANGUAGE ForeignFunctionInterface #-}

module Spike (main) where

import GHC.Wasm.Prim

foreign import javascript "((s) => { document.getElementById('log').innerText += s + '\\n'; })"
  js_log :: JSString -> IO ()

foreign import javascript "((url) => new WebSocket(url))"
  js_wsOpen :: JSString -> IO JSVal

foreign import javascript "wrapper"
  wrapCb :: IO () -> IO JSVal

foreign import javascript "((ws, cb) => { ws.onopen = cb; })"
  js_onOpen :: JSVal -> JSVal -> IO ()

-- | Called from JS after the page loads.
startSpike :: JSString -> IO ()
startSpike url = do
  js_log (toJSString "haskell: opening socket")
  ws <- js_wsOpen url
  cb <- wrapCb (js_log (toJSString "haskell: socket open callback fired"))
  js_onOpen ws cb

foreign export javascript "startSpike" startSpike :: JSString -> IO ()

main :: IO ()
main = pure ()
```

`examples/quickstart-chat/client-web-hs/spike/spike.cabal`:

```cabal
cabal-version:      3.0
name:               spike
version:            0.1.0.0
build-type:         Simple

executable spike
  default-language: GHC2021
  hs-source-dirs:   .
  main-is:          Spike.hs
  build-depends:    base, ghc-experimental
  ghc-options:      -no-hs-main -optl-mexec-model=reactor
                    -optl-Wl,--export=startSpike
                    -optl-Wl,--export=_initialize
                    -optl-Wl,--export-memory
```

`examples/quickstart-chat/client-web-hs/spike/cabal.project` (isolates the spike so `wasm32-wasi-cabal` does not pick up the repo-root project):

```
packages: .
```

> `-optl-Wl,--export=startSpike` is belt-and-braces; `foreign export javascript` also arranges the export. Keep both. `GHC.Wasm.Prim` (`JSString`/`JSVal`/`toJSString`/`fromJSString`/`foreign import javascript`) is provided by the `ghc-experimental` package on the wasm toolchain — hence the `ghc-experimental` build-dep. If the toolchain exposes it elsewhere, adjust the dep so the module resolves.

- [ ] **Step 3: Build script (wasm + post-link)**

`examples/quickstart-chat/client-web-hs/spike/build.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
wasm32-wasi-cabal build exe:spike
wasm="$(wasm32-wasi-cabal list-bin exe:spike)"
libdir="$(wasm32-wasi-ghc --print-libdir)"
cp "$wasm" ./spike.wasm
node "$libdir/post-link.mjs" -i ./spike.wasm -o ./ghc_wasm_jsffi.js
echo "built spike.wasm + ghc_wasm_jsffi.js"
```

> `post-link.mjs` lives under the GHC wasm libdir (ghc-wasm-meta ships it). If `--print-libdir` does not contain it, locate it with `find "$(dirname "$(command -v wasm32-wasi-ghc)")/.." -name post-link.mjs` and use that path. Report the resolved path in the task notes.

- [ ] **Step 4: Host page**

`examples/quickstart-chat/client-web-hs/spike/index.html`:

```html
<!doctype html>
<meta charset="utf-8" />
<title>JSFFI spike</title>
<pre id="log"></pre>
<script type="module">
  import { WASI, OpenFile, File, ConsoleStdout }
    from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/+esm";
  import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";

  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((m) => console.log("[wasm]", m)),
    ConsoleStdout.lineBuffered((m) => console.error("[wasm]", m)),
  ];
  const wasi = new WASI([], [], fds);
  const bytes = await (await fetch("./spike.wasm")).arrayBuffer();
  const mod = await WebAssembly.compile(bytes);
  const jsffi = {};
  const inst = await WebAssembly.instantiate(mod, {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: ghc_wasm_jsffi(jsffi),
  });
  Object.assign(jsffi, { instance: inst });
  wasi.initialize(inst);
  inst.exports._initialize?.();
  // Echo endpoint for the smoke test:
  inst.exports.startSpike("wss://ws.postman-echo.com/raw");
</script>
```

> The exact JSFFI wiring (the `ghc_wasm_jsffi` import object shape and whether it needs `{ instance }`) is defined by the generated `ghc_wasm_jsffi.js`. Follow the header comment that `post-link.mjs` emits at the top of that file — it documents the required instantiation. Adjust this page to match it. If the toolchain's convention differs, the generated file's comment is authoritative.

- [ ] **Step 5: Build, serve, observe — the checkpoint**

```bash
bash examples/quickstart-chat/client-web-hs/spike/build.sh
( cd examples/quickstart-chat/client-web-hs/spike && python3 -m http.server 8080 )
```

Open `http://localhost:8080/` (or `http://0.0.0.0:8080/` for remote viewing) and confirm the `<pre id="log">` shows both `haskell: opening socket` and `haskell: socket open callback fired`. That proves: wasm builds for the browser, `browser_wasi_shim` boots the RTS, `foreign import javascript` calls work, and a Haskell closure runs as a JS `onopen` callback (Haskell owns the socket).

**CHECKPOINT / DECISION:**
- **If the log shows both lines:** the "Haskell owns the socket" path works — proceed to B3/B4 as written.
- **If the callback line never fires** (RTS cannot re-enter from a JS callback in the reactor): fall back to the **Hybrid** design — JS owns the `WebSocket`; Haskell exposes `hs_onFrame :: bytes -> bytes-out-and-view` and `hs_send*`. B3 (`Chat.Web.Core`) is unchanged and reused as-is; only B4's `Ffi`/entry and B5's `run.mjs` change (JS holds the socket, calls exported byte functions). **Surface this outcome to the human before continuing.**

- [ ] **Step 6: Commit the spike + flake change**

```bash
git add flake.nix examples/quickstart-chat/client-web-hs/spike/
git commit -m "spike(client-web-hs): Haskell-owns-WebSocket JSFFI smoke test + node/python in wasm shell"
```

---

### Task B3: `Chat.Web.Core` pure protocol/view core + tests (TDD)

**Files:**
- Create: `examples/quickstart-chat/client-web-hs/chat-web.cabal`
- Create: `examples/quickstart-chat/client-web-hs/src/Chat/Web/Core.hs`
- Create: `examples/quickstart-chat/client-web-hs/test/Spec.hs`
- Create: `examples/quickstart-chat/client-web-hs/test/Chat/Web/CoreSpec.hs`
- Modify: `cabal.project`

- [ ] **Step 1: Create the package (native library + test build only for now)**

`examples/quickstart-chat/client-web-hs/chat-web.cabal`:

```cabal
cabal-version:      3.0
name:               chat-web
version:            0.1.0.0
synopsis:           quickstart-chat browser client (Haskell → wasm)
license:            MIT
build-type:         Simple

flag wasm
  description: Build the wasm reactor for the browser client.
  default:     False
  manual:      True

common extensions
  default-language:   GHC2021
  default-extensions: DataKinds
                      DuplicateRecordFields
                      LambdaCase
                      OverloadedRecordDot
                      OverloadedStrings
                      TypeApplications
                      NoFieldSelectors

library
  import:           extensions
  hs-source-dirs:   src
  exposed-modules:  Chat.Web.Core
  build-depends:    base
                  , text
                  , bytestring
                  , containers
                  , hs-spacetime:spacetime-client-core
                  , hs-spacetime:bsatn
                  , hs-spacetime:spacetime-server
                  , chat-module
  ghc-options:      -Wall

test-suite chat-web-test
  import:           extensions
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Spec.hs
  other-modules:    Chat.Web.CoreSpec
  build-depends:    base
                  , text
                  , bytestring
                  , containers
                  , hs-spacetime:spacetime-client-core
                  , hs-spacetime:bsatn
                  , hs-spacetime:spacetime-server
                  , chat-module
                  , chat-web
                  , hspec
  ghc-options:      -Wall
```

Append to `cabal.project`:

```
          examples/quickstart-chat/client-web-hs
```

- [ ] **Step 2: Write failing tests**

`examples/quickstart-chat/client-web-hs/test/Spec.hs`:

```haskell
module Main (main) where

import qualified Chat.Web.CoreSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec Chat.Web.CoreSpec.spec
```

`examples/quickstart-chat/client-web-hs/test/Chat/Web/CoreSpec.hs`:

```haskell
module Chat.Web.CoreSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Test.Hspec

import Chat (app)
import Chat.Web.Core
import SpacetimeDB.Protocol.Messages (encodeSubscribe)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Server.Table (tableName)

spec :: Spec
spec = do
  describe "decodeFrameNone" $ do
    it "rejects a frame whose compression tag is not 0" $
      decodeFrameNone (BS.pack [1, 2, 3]) `shouldSatisfy` isLeft
    it "rejects an empty frame" $
      decodeFrameNone BS.empty `shouldSatisfy` isLeft

  describe "subscribeBytes" $
    it "matches the native encodeSubscribe wire bytes" $ do
      -- Browser subscribes to user (qsid 1) then message (qsid 2).
      let userSql = "SELECT * FROM " <> tableName app.user
          native = runEncoder (\() -> encodeSubscribe 1 1 [userSql]) ()
      subscribeBytes 1 userSql `shouldBe` native

  describe "renderHtml" $
    it "escapes angle brackets in message text" $
      T.isInfixOf "&lt;script&gt;" (renderHtml (modelWithMessage "<script>")) `shouldBe` True
 where
  isLeft = either (const True) (const False)
```

> `modelWithMessage :: Text -> WebModel` is a test helper you add to `Chat.Web.Core` exports: builds a `WebModel` containing one message from an anonymous sender with the given text. Keep it tiny; it exists so the escaping test needs no live decode.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cabal test chat-web:chat-web-test`
Expected: FAIL — `Chat.Web.Core` unimplemented.

- [ ] **Step 4: Implement `Chat.Web.Core`**

`examples/quickstart-chat/client-web-hs/src/Chat/Web/Core.hs`:

```haskell
module Chat.Web.Core
  ( WebModel (..)
  , emptyModel
  , decodeFrameNone
  , applyMessage
  , renderHtml
  , subscribeBytes
  , callReducerBytes
  , modelWithMessage
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)

import Chat (Message (..), User (..))
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.BSATN.Types (Identity, Timestamp (..), identityFromInteger, identityToHex)
import SpacetimeDB.Protocol.Messages
  ( QuerySetUpdate (..)
  , QueryRows (..)
  , ReducerOutcome (..)
  , ServerMessage (..)
  , SingleTableRows (..)
  , TableUpdate (..)
  , TableUpdateRows (..)
  , decodeServerMessage
  , encodeCallReducer
  , encodeSubscribe
  )
import SpacetimeDB.Server.HKD (View (Value))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (decodeVal, encodeVal))

data WebModel = WebModel
  { wmNames :: !(Map Identity Text)
  , wmMessages :: ![Message 'Value]
  , wmSelf :: !(Maybe Identity)
  }

emptyModel :: WebModel
emptyModel = WebModel M.empty [] Nothing

-- | Decode a compression=None server frame: a 0x00 tag then a BSATN ServerMessage.
decodeFrameNone :: ByteString -> Either Text ServerMessage
decodeFrameNone bs = case BS.uncons bs of
  Nothing -> Left "empty frame"
  Just (0, rest) -> either (Left . T.pack . show) Right (runExact decodeServerMessage rest)
  Just (t, _) -> Left ("unexpected compression tag " <> T.pack (show t))

applyMessage :: ServerMessage -> WebModel -> WebModel
applyMessage msg m = case msg of
  InitialConnection ident _conn _tok -> m {wmSelf = Just ident}
  SubscribeApplied _ _ (QueryRows tables) -> foldr applyInitial m tables
  TransactionUpdate qsus -> foldr applyQsu m qsus
  ReducerResult _ _ (OutcomeOk _ qsus) -> foldr applyQsu m qsus
  _ -> m
 where
  applyInitial (SingleTableRows tbl rows) acc = ingest tbl rows [] acc
  applyQsu (QuerySetUpdate _ tus) acc = foldr applyTu acc tus
  applyTu (TableUpdate tbl trs) acc = foldr (applyTr tbl) acc trs
  applyTr tbl (PersistentTable ins del) acc = ingest tbl ins del acc
  applyTr tbl (EventTable evs) acc = ingest tbl evs [] acc

-- | Route a table's inserted/deleted rows into the model.
ingest :: Text -> [ByteString] -> [ByteString] -> WebModel -> WebModel
ingest tbl ins del m
  | tbl == "user" =
      let addNames = [u | Right u <- map (runExact (decodeVal @(User 'Value))) ins]
          delNames = [u | Right u <- map (runExact (decodeVal @(User 'Value))) del]
       in m {wmNames = foldr addU (foldr delU (wmNames m) delNames) addNames}
  | tbl == "message" =
      let newMsgs = [x | Right x <- map (runExact (decodeVal @(Message 'Value))) ins]
       in m {wmMessages = sortOn sentOf (wmMessages m ++ newMsgs)}
  | otherwise = m
 where
  addU (User i mn _) mp = maybe mp (\n -> if T.null n then mp else M.insert i n mp) mn
  delU (User i _ _) mp = M.delete i mp
  sentOf (Message _ ts _) = ts

displayName :: WebModel -> Identity -> Text
displayName m i = case M.lookup i (wmNames m) of
  Just n -> n
  Nothing -> "user-" <> T.take 8 (identityToHex i)

renderHtml :: WebModel -> Text
renderHtml m = T.intercalate "\n" [line msg | msg <- wmMessages m]
 where
  line (Message sndr _ txt) =
    "<div class=\"msg\"><b>" <> esc (displayName m sndr) <> "</b>: " <> esc txt <> "</div>"

-- Composition applies right-to-left, so '&' is escaped first (a real '<'
-- becomes "&lt;", never "&amp;lt;").
esc :: Text -> Text
esc = T.replace "<" "&lt;" . T.replace ">" "&gt;" . T.replace "&" "&amp;"

-- | Outbound Subscribe bytes for a single query at (rid=qsid=n). Raw, no tag.
subscribeBytes :: Word32 -> Text -> ByteString
subscribeBytes n query = runEncoder (\() -> encodeSubscribe n n [query]) ()

-- | Outbound CallReducer bytes. Raw, no tag.
callReducerBytes :: SpacetimeType a => Word32 -> Text -> a -> ByteString
callReducerBytes rid name argv =
  runEncoder (\() -> encodeCallReducer rid 0 name (runEncoder encodeVal argv)) ()

-- Test helper: a model holding one message with the given text.
modelWithMessage :: Text -> WebModel
modelWithMessage t =
  emptyModel {wmMessages = [Message (identityFromInteger 0) (Timestamp 0) t]}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cabal test chat-web:chat-web-test`
Expected: PASS. The `subscribeBytes` golden proves the browser produces byte-identical outbound frames to the native SDK.

- [ ] **Step 6: Confirm the core cross-compiles**

Run (in `.#wasm`): `wasm32-wasi-cabal build -fwasm chat-web:lib:chat-web`
Expected: builds (all deps — `spacetime-client-core`, `bsatn`, `spacetime-server`, `chat-module` — are wasm-safe).

- [ ] **Step 7: Commit**

```bash
git add examples/quickstart-chat/client-web-hs/chat-web.cabal examples/quickstart-chat/client-web-hs/src examples/quickstart-chat/client-web-hs/test cabal.project
git commit -m "feat(client-web-hs): pure Chat.Web.Core (frame decode, model, render, outbound) + tests"
```

---

### Task B4: JSFFI runtime + reactor entry

**Files:**
- Create: `examples/quickstart-chat/client-web-hs/src/Chat/Web/Ffi.hs`
- Create: `examples/quickstart-chat/client-web-hs/app/ChatWeb.hs`
- Modify: `examples/quickstart-chat/client-web-hs/chat-web.cabal` (add the wasm executable)

> If the B2 checkpoint chose the **Hybrid** fallback, implement this task's *Hybrid* variant (noted at each step): JS owns the socket and calls exported byte functions, instead of Haskell holding the `WebSocket` handle. `Chat.Web.Core` is identical either way.

- [ ] **Step 1: JSFFI bindings + IORef runtime**

`examples/quickstart-chat/client-web-hs/src/Chat/Web/Ffi.hs`:

```haskell
{-# LANGUAGE ForeignFunctionInterface #-}

module Chat.Web.Ffi
  ( startClient
  , sendChat
  , setChatName
  ) where

import Data.IORef
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Word (Word32)
import System.IO.Unsafe (unsafePerformIO)

import GHC.Wasm.Prim

import Chat (app)
import qualified Chat as C
import Chat.Web.Core
import SpacetimeDB.Server.Reducer (reducerName)
import SpacetimeDB.Server.Table (tableName)

-- Single-threaded browser runtime: one global model + the live socket.
data Runtime = Runtime
  { rtModel :: IORef WebModel
  , rtSock :: IORef (Maybe JSVal)
  , rtRid :: IORef Word32
  }

runtime :: Runtime
runtime = unsafePerformIO (Runtime <$> newIORef emptyModel <*> newIORef Nothing <*> newIORef 100)
{-# NOINLINE runtime #-}

--------------------------------------------------------------------------------
-- JS imports (Haskell owns the socket)

foreign import javascript "((url, proto) => new WebSocket(url, proto))"
  js_wsOpen :: JSString -> JSString -> IO JSVal

foreign import javascript "((ws) => { ws.binaryType = 'arraybuffer'; })"
  js_wsBinary :: JSVal -> IO ()

foreign import javascript "((ws, cb) => { ws.onopen = cb; })"
  js_onOpen :: JSVal -> JSVal -> IO ()

foreign import javascript "((ws, cb) => { ws.onmessage = (e) => cb(new Uint8Array(e.data)); })"
  js_onMessage :: JSVal -> JSVal -> IO ()

foreign import javascript "((ws, bytes) => ws.send(bytes))"
  js_wsSend :: JSVal -> JSVal -> IO ()

foreign import javascript "wrapper"
  wrapIO :: IO () -> IO JSVal

foreign import javascript "wrapper"
  wrapBytesCb :: (JSVal -> IO ()) -> IO JSVal

foreign import javascript "((s) => { document.getElementById('log').innerHTML = s; })"
  js_setLog :: JSString -> IO ()

-- Marshalling helpers between JS Uint8Array and Haskell ByteString.
foreign import javascript "((a) => a.length)"
  js_len :: JSVal -> IO Int

foreign import javascript "((a, i) => a[i])"
  js_idx :: JSVal -> Int -> IO Int

foreign import javascript "((n) => new Uint8Array(n))"
  js_newBytes :: Int -> IO JSVal

foreign import javascript "((a, i, v) => { a[i] = v; })"
  js_setByte :: JSVal -> Int -> Int -> IO ()

fromJSBytes :: JSVal -> IO BS.ByteString
fromJSBytes arr = do
  n <- js_len arr
  BS.pack <$> mapM (\i -> fromIntegral <$> js_idx arr i) [0 .. n - 1]

toJSBytes :: BS.ByteString -> IO JSVal
toJSBytes bs = do
  arr <- js_newBytes (BS.length bs)
  mapM_ (\(i, w) -> js_setByte arr i (fromIntegral w)) (zip [0 ..] (BS.unpack bs))
  pure arr

--------------------------------------------------------------------------------
-- Exported entry points

-- | Open the socket and register callbacks. @host@ is like "127.0.0.1:3000".
startClient :: JSString -> JSString -> IO ()
startClient jsHost jsDb = do
  let host = T.pack (fromJSString jsHost)
      db = T.pack (fromJSString jsDb)
      url = "ws://" <> host <> "/v1/database/" <> db <> "/subscribe?compression=None"
  ws <- js_wsOpen (toJSString (T.unpack url)) (toJSString "v2.bsatn.spacetimedb")
  js_wsBinary ws
  writeIORef (rtSock runtime) (Just ws)
  openCb <- wrapIO (onOpen ws)
  js_onOpen ws openCb
  msgCb <- wrapBytesCb onFrameArr
  js_onMessage ws msgCb

onOpen :: JSVal -> IO ()
onOpen ws = do
  let userSql = "SELECT * FROM " <> tableName app.user
      msgSql = "SELECT * FROM " <> tableName app.message
  send ws (subscribeBytes 1 userSql)
  send ws (subscribeBytes 2 msgSql)

-- | Message handler: the JS glue passes a Uint8Array (e.data as bytes).
onFrameArr :: JSVal -> IO ()
onFrameArr arr = do
  bs <- fromJSBytes arr
  case decodeFrameNone bs of
    Left _ -> pure ()
    Right msg -> do
      modifyIORef' (rtModel runtime) (applyMessage msg)
      render

render :: IO ()
render = do
  m <- readIORef (rtModel runtime)
  js_setLog (toJSString (T.unpack (renderHtml m)))

send :: JSVal -> BS.ByteString -> IO ()
send ws bs = toJSBytes bs >>= js_wsSend ws

nextRid :: IO Word32
nextRid = atomicModifyIORef' (rtRid runtime) (\r -> (r + 1, r))

sendChat :: JSString -> IO ()
sendChat jsText = withSock $ \ws -> do
  rid <- nextRid
  send ws (callReducerBytes rid (reducerName app.sendMessage) (C.SendMessageArgs (T.pack (fromJSString jsText))))

setChatName :: JSString -> IO ()
setChatName jsName = withSock $ \ws -> do
  rid <- nextRid
  send ws (callReducerBytes rid (reducerName app.setName) (C.SetNameArgs (T.pack (fromJSString jsName))))

withSock :: (JSVal -> IO ()) -> IO ()
withSock k = readIORef (rtSock runtime) >>= maybe (pure ()) k
```

> The `js_onMessage` glue extracts `new Uint8Array(e.data)` and calls the wrapped Haskell handler (`onFrameArr`) with it; `onFrameArr` marshals it to a `ByteString` via `fromJSBytes`.

- [ ] **Step 2: Reactor entry with exports**

`examples/quickstart-chat/client-web-hs/app/ChatWeb.hs`:

```haskell
{-# LANGUAGE ForeignFunctionInterface #-}

module ChatWeb (main) where

import GHC.Wasm.Prim
import Chat.Web.Ffi (sendChat, setChatName, startClient)

foreign export javascript "startClient" startClient :: JSString -> JSString -> IO ()
foreign export javascript "sendChat" sendChat :: JSString -> IO ()
foreign export javascript "setChatName" setChatName :: JSString -> IO ()

main :: IO ()
main = pure ()
```

- [ ] **Step 3: Add the wasm executable stanza to `chat-web.cabal`**

```cabal
executable chat-web
  import:           extensions
  hs-source-dirs:   app
  main-is:          ChatWeb.hs
  if !flag(wasm)
    buildable: False
  if flag(wasm)
    build-depends:  base
                  , text
                  , bytestring
                  , ghc-experimental
                  , chat-web
    ghc-options:    -no-hs-main -optl-mexec-model=reactor
                    -optl-Wl,--export=startClient
                    -optl-Wl,--export=sendChat
                    -optl-Wl,--export=setChatName
                    -optl-Wl,--export=_initialize
                    -optl-Wl,--export-memory
```

Also add `Chat.Web.Ffi` to the `library` `exposed-modules` and add `bytestring` (already present) — the `library` must expose `Chat.Web.Ffi` so the executable can import it. Since `Chat.Web.Ffi` uses `GHC.Wasm.Prim`, guard it: add a second library-condition so the FFI module is only built under wasm.

Update the `library` stanza to:

```cabal
library
  import:           extensions
  hs-source-dirs:   src
  exposed-modules:  Chat.Web.Core
  build-depends:    base, text, bytestring, containers
                  , hs-spacetime:spacetime-client-core
                  , hs-spacetime:bsatn
                  , hs-spacetime:spacetime-server
                  , chat-module
  if flag(wasm)
    exposed-modules: Chat.Web.Ffi
    build-depends:   ghc-experimental
  ghc-options:      -Wall
```

- [ ] **Step 4: wasm build**

Run (in `.#wasm`): `wasm32-wasi-cabal build -fwasm chat-web:exe:chat-web`
Expected: builds a reactor wasm with the three exports. Fix any `GHC.Wasm.Prim` API mismatch (`toJSString`/`fromJSString`/`JSString`/`JSVal` are the stable names).

- [ ] **Step 5: Commit**

```bash
git add examples/quickstart-chat/client-web-hs/src/Chat/Web/Ffi.hs examples/quickstart-chat/client-web-hs/app examples/quickstart-chat/client-web-hs/chat-web.cabal
git commit -m "feat(client-web-hs): JSFFI runtime + reactor entry (Haskell owns the socket)"
```

---

### Task B5: Build script, host page, live smoke

**Files:**
- Create: `examples/quickstart-chat/client-web-hs/scripts/build-web-hs.sh`
- Create: `examples/quickstart-chat/client-web-hs/web/index.html`
- Create: `examples/quickstart-chat/client-web-hs/web/run.mjs`

- [ ] **Step 1: Build script (wasm → post-link → dist/)**

`examples/quickstart-chat/client-web-hs/scripts/build-web-hs.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dist="$here/dist"
mkdir -p "$dist"
cd "$here"

wasm32-wasi-cabal build -fwasm exe:chat-web
wasm="$(wasm32-wasi-cabal list-bin -fwasm exe:chat-web)"
cp "$wasm" "$dist/chat-web.wasm"

libdir="$(wasm32-wasi-ghc --print-libdir)"
postlink="$libdir/post-link.mjs"
[ -f "$postlink" ] || postlink="$(find "$(dirname "$(command -v wasm32-wasi-ghc)")/.." -name post-link.mjs | head -n1)"
node "$postlink" -i "$dist/chat-web.wasm" -o "$dist/ghc_wasm_jsffi.js"

cp "$here/web/index.html" "$dist/index.html"
cp "$here/web/run.mjs" "$dist/run.mjs"
echo "built $dist (chat-web.wasm, ghc_wasm_jsffi.js, index.html, run.mjs)"
```

- [ ] **Step 2: Host page + loader**

`examples/quickstart-chat/client-web-hs/web/index.html`:

```html
<!doctype html>
<meta charset="utf-8" />
<title>quickstart-chat — Haskell in the browser</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; }
  #log { border: 1px solid #ccc; padding: .5rem; min-height: 12rem; }
  .msg { padding: .1rem 0; }
  form { display: flex; gap: .5rem; margin-top: .5rem; }
  input { flex: 1; }
</style>
<h1>quickstart-chat <small>(Haskell → wasm)</small></h1>
<div id="log"></div>
<form id="nameForm"><input id="name" placeholder="set your name" /><button>set name</button></form>
<form id="msgForm"><input id="msg" placeholder="message" /><button>send</button></form>
<script type="module" src="./run.mjs"></script>
```

`examples/quickstart-chat/client-web-hs/web/run.mjs`:

```javascript
import { WASI, OpenFile, File, ConsoleStdout }
  from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/+esm";
import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";

const params = new URLSearchParams(location.search);
const host = params.get("host") ?? "127.0.0.1:3000";
const db = params.get("db") ?? "quickstart-chat";

const fds = [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered((m) => console.log("[wasm]", m)),
  ConsoleStdout.lineBuffered((m) => console.error("[wasm]", m)),
];
const wasi = new WASI([], [], fds);
const bytes = await (await fetch("./chat-web.wasm")).arrayBuffer();
const mod = await WebAssembly.compile(bytes);
const jsffi = {};
const inst = await WebAssembly.instantiate(mod, {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghc_wasm_jsffi(jsffi),
});
Object.assign(jsffi, { instance: inst });
wasi.initialize(inst);
inst.exports._initialize?.();
inst.exports.startClient(host, db);

document.getElementById("nameForm").addEventListener("submit", (e) => {
  e.preventDefault();
  inst.exports.setChatName(document.getElementById("name").value);
});
document.getElementById("msgForm").addEventListener("submit", (e) => {
  e.preventDefault();
  const el = document.getElementById("msg");
  inst.exports.sendChat(el.value);
  el.value = "";
});
```

> The `ghc_wasm_jsffi` import-object convention (whether it takes the instance via a shared object like `Object.assign(jsffi, {instance})` or another shape) is dictated by the header comment in the generated `dist/ghc_wasm_jsffi.js`. Follow that comment; adjust `run.mjs` to match if it differs from the pattern above (which mirrors the B2 spike).

- [ ] **Step 3: Build + serve + smoke against a live module**

Prereq: publish `quickstart-chat` (server track already done) and run SpacetimeDB on `127.0.0.1:3000`.

```bash
bash examples/quickstart-chat/client-web-hs/scripts/build-web-hs.sh
( cd examples/quickstart-chat/client-web-hs/dist && python3 -m http.server 8080 --bind 0.0.0.0 )
```

Open `http://<host>:8080/?host=127.0.0.1:3000&db=quickstart-chat`. Verify: the page connects, set a name, send a message, and it appears in `#log`. Cross-check by sending a message from the TUI client (Track A) or the `spacetime` CLI and confirming it shows up in the browser. Record the outcome in the PR.

- [ ] **Step 4: Commit**

```bash
git add examples/quickstart-chat/client-web-hs/scripts examples/quickstart-chat/client-web-hs/web
git commit -m "feat(client-web-hs): build script + host page + loader"
```

---

### Task B6: Docs + cleanup

**Files:**
- Create: `examples/quickstart-chat/client-web-hs/README.md`
- Modify: `examples/quickstart-chat/README.md`
- Delete: `examples/quickstart-chat/client-web-hs/spike/` (throwaway)
- Modify: `examples/quickstart-chat/client-web-hs/chat-web.cabal` (drop the spike if it was ever added to cabal.project — it was standalone, so just remove the directory)

- [ ] **Step 1: Write the browser client README**

`examples/quickstart-chat/client-web-hs/README.md`: document the toolchain (`.#wasm`), `bash scripts/build-web-hs.sh`, serving `dist/` with `python3 -m http.server`, the `?host=&db=` query params, and a one-paragraph explanation that the WebSocket is owned by Haskell via JSFFI (or, if the fallback was taken, that JS owns the socket and Haskell owns the protocol/view — state whichever is true).

- [ ] **Step 2: Link both clients from the example README**

Append a "Haskell browser client (wasm)" section to `examples/quickstart-chat/README.md`.

- [ ] **Step 3: Remove the spike**

```bash
git rm -r examples/quickstart-chat/client-web-hs/spike
```

- [ ] **Step 4: Full test sweep**

Run (in `.#dev`): `cabal test chat-tui:chat-tui-test chat-web:chat-web-test`
Expected: both green. Then `cabal build all` to confirm nothing else regressed (the native `hs-spacetime` library and `chat-module` are untouched).

- [ ] **Step 5: Commit**

```bash
git add examples/quickstart-chat/client-web-hs/README.md examples/quickstart-chat/README.md
git commit -m "docs(client-web-hs): usage + remove spike"
```

---

## Final Review

After both tracks are complete, dispatch a final code review over the whole branch (spec compliance + quality), then use superpowers:finishing-a-development-branch. Confirm:
- Native `hs-spacetime` library + `chat-module` sources unchanged (only `hs-spacetime.cabal` gained a sublibrary stanza).
- CI (`.#dev`) builds/tests both new packages green; the wasm builds are exercised in `.#wasm` (document the manual browser smoke — no headless suite in v1).
- `subscribeBytes` golden proves browser↔native wire parity.
