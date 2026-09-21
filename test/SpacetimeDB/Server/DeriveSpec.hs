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

import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server.Derive
import SpacetimeDB.Server.HKD
import SpacetimeDB.Server.Reducer (Reducer, reducerName)
import SpacetimeDB.Server.Schema (Lifecycle (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import SpacetimeDB.Server.Table (Table, tableName)
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

spec :: Spec
spec = describe "Server.Derive.deriveApp" $
  it "fills handle names from field selectors (camelCase to snake_case)" $ do
    tableName app.widget `shouldBe` "widget"
    reducerName app.addWidget `shouldBe` "add_widget"
    lifecycleHookName app.init `shouldBe` "init"
