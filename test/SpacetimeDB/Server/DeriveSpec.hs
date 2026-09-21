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
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server (ModuleDef, describeBytes)
import SpacetimeDB.Server.Derive
import SpacetimeDB.Server.HKD
import SpacetimeDB.Server.Reducer (Reducer, reducerName)
import SpacetimeDB.Server.Schema (Lifecycle (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import SpacetimeDB.Server.Table (Table, tableName)
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
