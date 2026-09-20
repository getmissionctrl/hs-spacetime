{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module SpacetimeDB.Server.ModuleSpec (spec) where

import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server (ModuleDef, describeBytes)
import SpacetimeDB.Server.Module
  ( ColumnAttr (..)
  , Lifecycle (..)
  , Reducer
  , defineModule
  , lifecycleReg
  , reducer
  , reducerReg
  , tableReg
  , tableWith
  )
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import SpacetimeDB.Server.Table (Table, table)
import Test.Hspec

-- The table row and reducer argument types, declared as plain Haskell records.
data Event = Event {who :: Text, at :: Int64}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (SpacetimeType)

newtype RecordArgs = RecordArgs {note :: Text}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

newtype RecordNArgs = RecordNArgs {count :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

eventTable :: Table Event
eventTable = table "event"

deleteAll :: Reducer ()
deleteAll = reducer "delete_all"

record :: Reducer RecordArgs
record = reducer "record"

recordN :: Reducer RecordNArgs
recordN = reducer "record_n"

-- The whole @event@ module authored entirely in Haskell types (handlers are
-- stubs here; reducer behaviour is covered by DispatchSpec/TableSpec).
theModule :: ModuleDef
theModule =
  defineModule
    [tableReg eventTable]
    [ reducerReg deleteAll (\() -> pure ())
    , reducerReg record (\(RecordArgs _) -> pure ())
    , reducerReg recordN (\(RecordNArgs _) -> pure ())
    ]

-- A table with a primary key + auto-inc column, and a lifecycle reducer.
data Widget = Widget {id :: Word64, name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

data AddWidgetArgs = AddWidgetArgs {name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

widgetTable :: Table Widget
widgetTable = table "widget"

addWidget :: Reducer AddWidgetArgs
addWidget = reducer "add_widget"

initR :: Reducer ()
initR = reducer "init"

widgetModule :: ModuleDef
widgetModule =
  defineModule
    [tableWith widgetTable [PrimaryKey "id", AutoInc "id"]]
    [ reducerReg addWidget (\(AddWidgetArgs _ _) -> pure ())
    , lifecycleReg Init initR (\() -> pure ())
    ]

spec :: Spec
spec = describe "Server.Module" $ do
  it "defineModule emits schema bytes byte-identical to the Rust event golden" $ do
    golden <- BS.readFile "phase1/golden/event.schema.bsatn"
    describeBytes theModule `shouldBe` golden

  it "defineModule with PK/auto-inc/lifecycle matches the Rust widget golden" $ do
    golden <- BS.readFile "phase2/golden/widget.schema.bsatn"
    describeBytes widgetModule `shouldBe` golden
