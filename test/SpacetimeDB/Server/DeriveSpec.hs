{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE NoFieldSelectors #-}

module SpacetimeDB.Server.DeriveSpec (spec) where

import qualified Data.ByteString as BS
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Server (ModuleDef, describeBytes, dispatchReducer, mkContext)
import SpacetimeDB.Server.Derive
import SpacetimeDB.Server.HKD
import SpacetimeDB.Server.Internal (Backend (..), TableId (..))
import SpacetimeDB.Server.Reducer (Reducer, reducerName)
import SpacetimeDB.Server.Schema (Lifecycle (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Table (Table, insertRow, tableName)
import SpacetimeDB.Server.Types (ReducerM)
import Test.Hspec

data Widget f = Widget
  { id :: Column f Word64 '[ 'Pk, 'AutoInc]
  , name :: Column f Text '[]
  , quantity :: Column f Word32 '[]
  }
  deriving stock (Generic)

deriving anyclass instance SpacetimeType (Widget 'Value)

data AddWidgetArgs = AddWidgetArgs {name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

data App = App
  { widget :: Table Widget
  , addWidget :: Reducer AddWidgetArgs
  , init :: LifecycleHook 'Init
  }
  deriving stock (Generic)

app :: App
app = deriveApp

data WidgetHandlers = WidgetHandlers
  { addWidget :: AddWidgetArgs -> ReducerM ()
  , init :: () -> ReducerM ()
  }
  deriving stock (Generic)

widgetModule :: ModuleDef
widgetModule =
  deriveModule
    app
    WidgetHandlers
      { addWidget = \_ -> pure ()
      , init = \() -> pure ()
      }

-- Negative compile proofs (verified out-of-band; see the design's exhaustiveness
-- guarantee). @deriveModule@ requires @AppSigs (Rep app) ~ HandlerSigs (Rep
-- handlers)@, so a handlers record that does not match the App's reducer fields
-- position-for-position is a *compile* error:
--
--   * Missing handler (App has @init@, handlers omit it):
--       Couldn't match type: '[ '("init", ())] with: '[]
--         arising from a use of 'deriveModule'
--
--   * Wrong argument type (handler takes @RecordArgs@, App declares @AddWidgetArgs@):
--       Couldn't match type 'AddWidgetArgs' with 'RecordArgs'
--         arising from a use of 'deriveModule'
--
-- (A renamed or reordered handler fails the same way via a symbol mismatch.)

-- A live variant whose add_widget handler actually inserts a row.
widgetModuleLive :: ModuleDef
widgetModuleLive =
  deriveModule
    app
    WidgetHandlers
      { addWidget = \(AddWidgetArgs n q) -> insertRow app.widget (Widget 0 n q)
      , init = \() -> insertRow app.widget (Widget 0 "seed" 1)
      }

-- Event fixture: reproduces the phase-1 event golden through the derived path.
data Event f = Event {who :: Column f Text '[], at :: Column f Int64 '[]}
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (Event 'Value)

newtype RecordArgs = RecordArgs {note :: Text}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)
newtype RecordNArgs = RecordNArgs {count :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

data EventApp = EventApp
  { event :: Table Event
  , deleteAll :: Reducer ()
  , record :: Reducer RecordArgs
  , recordN :: Reducer RecordNArgs
  }
  deriving stock (Generic)

eventApp :: EventApp
eventApp = deriveApp

data EventHandlers = EventHandlers
  { deleteAll :: () -> ReducerM ()
  , record :: RecordArgs -> ReducerM ()
  , recordN :: RecordNArgs -> ReducerM ()
  }
  deriving stock (Generic)

eventModule :: ModuleDef
eventModule =
  deriveModule
    eventApp
    EventHandlers
      { deleteAll = \() -> pure ()
      , record = \_ -> pure ()
      , recordN = \_ -> pure ()
      }

spec :: Spec
spec = describe "Server.Derive" $ do
  describe "deriveApp" $
    it "fills handle names from field selectors (camelCase to snake_case)" $ do
      tableName app.widget `shouldBe` "widget"
      reducerName app.addWidget `shouldBe` "add_widget"
      lifecycleHookName app.init `shouldBe` "init"

  describe "deriveModule" $ do
    it "widget App derives schema bytes byte-identical to the Rust golden" $ do
      golden <- BS.readFile "phase2/golden/widget.schema.bsatn"
      describeBytes widgetModule `shouldBe` golden

    it "event App derives schema bytes byte-identical to the Rust golden" $ do
      golden <- BS.readFile "phase1/golden/event.schema.bsatn"
      describeBytes eventModule `shouldBe` golden

    it "dispatches reducer 0 (add_widget) through the derived handler" $ do
      inserted <- newIORef []
      let be =
            Backend
              { tableId = \_ -> pure (Right (TableId 1))
              , insert = \_ row -> modifyIORef' inserted (++ [row]) >> pure (Right ())
              , scan = \_ -> pure (Right BS.empty)
              , delete = \_ _ -> pure (Right ())
              , log = \_ -> pure ()
              }
          args = runEncoder encodeVal (AddWidgetArgs "a" 10)
      -- add_widget is reducer id 0 (first reducer field of App / handlers)
      r <- dispatchReducer widgetModuleLive 0 (mkContext 0 0 0 0 0 0 0) args be
      r `shouldBe` Right ()
      rows <- readIORef inserted
      length rows `shouldBe` 1
