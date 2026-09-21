{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE NoFieldSelectors #-}

{- | Compile-level proof that one set of Haskell types + handles drives the typed
client: the same @Widget@/@AddWidgetArgs@ records, @widgetTable@ and @addWidget@
handles a server module would use are consumed directly by the client API.
-}
module SpacetimeDB.Client.TypedSpec (spec) where

import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Client (Client, Config, builder)
import SpacetimeDB.Client.Typed (callTyped, subscribeTable)
import SpacetimeDB.Server.HKD (Column, View (..))
import SpacetimeDB.Server.Reducer (Reducer, reducer)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import SpacetimeDB.Server.Table (Table, table)
import Test.Hspec

data Widget f = Widget
  { id :: Column f Word64 '[]
  , name :: Column f Text '[]
  , quantity :: Column f Word32 '[]
  }
  deriving stock (Generic)
deriving stock instance Show (Widget 'Value)
deriving anyclass instance SpacetimeType (Widget 'Value)

data AddWidgetArgs = AddWidgetArgs {name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

widgetTable :: Table Widget
widgetTable = table "widget"

addWidget :: Reducer AddWidgetArgs
addWidget = reducer "add_widget"

-- Typed subscription: delivers decoded [Widget], no manual byte decoding.
clientConfig :: Config
clientConfig =
  subscribeTable
    widgetTable
    "SELECT * FROM widget"
    (\inserts _deletes -> mapM_ print (inserts :: [Widget 'Value]))
    (builder "localhost" 3000 "widget-hs")

-- Typed reducer call: name from the handle, argument type checked.
doCall :: Client -> IO ()
doCall c = callTyped c addWidget (AddWidgetArgs "a" 10) (\_ -> pure ())

spec :: Spec
spec =
  describe "Client.Typed" $
    it "typed client composes over shared Table/Reducer/SpacetimeType" $
      (clientConfig, doCall) `seq`
        (True `shouldBe` True)
