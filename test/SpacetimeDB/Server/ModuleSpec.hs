{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module SpacetimeDB.Server.ModuleSpec (spec) where

import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Generics (Generic)
import SpacetimeDB.Server (ModuleDef, describeBytes)
import SpacetimeDB.Server.Module (defineModule, reducerReg, tableReg)
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

-- The whole @event@ module authored entirely in Haskell types (handlers are
-- stubs here; reducer behaviour is covered by DispatchSpec/TableSpec).
theModule :: ModuleDef
theModule =
  defineModule
    [tableReg eventTable]
    [ reducerReg "delete_all" (\() -> pure ())
    , reducerReg "record" (\(RecordArgs _) -> pure ())
    , reducerReg "record_n" (\(RecordNArgs _) -> pure ())
    ]

spec :: Spec
spec = describe "Server.Module" $
  it "defineModule emits schema bytes byte-identical to the Rust event golden" $ do
    golden <- BS.readFile "phase1/golden/event.schema.bsatn"
    describeBytes theModule `shouldBe` golden
