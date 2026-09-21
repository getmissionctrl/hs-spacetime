{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoFieldSelectors #-}

module SpacetimeDB.Server.HKDSpec (spec) where

import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server.HKD
import SpacetimeDB.Server.Schema (AlgType (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import Test.Hspec

-- A row whose value view is a plain record (compile-level check).
data Widget f = Widget
  { id :: Column f Word64 '[ 'Pk, 'AutoInc]
  , name :: Column f Text '[]
  , quantity :: Column f Word32 '[]
  }
  deriving stock (Generic)

deriving anyclass instance SpacetimeType (Widget 'Value)

widgetValue :: Widget 'Value
widgetValue = Widget 7 "w" 3

spec :: Spec
spec = describe "Server.HKD" $ do
  it "Value view exposes raw field types" $
    (widgetValue.id, widgetValue.quantity) `shouldBe` (7, 3)

  it "reflects a Schema-view column to its AlgType and attrs" $ do
    colAlgType @(ColInfo Word64 '[ 'Pk, 'AutoInc]) `shouldBe` TU64
    colAttrs @(ColInfo Word64 '[ 'Pk, 'AutoInc]) `shouldBe` [ColPk, ColAutoInc]
