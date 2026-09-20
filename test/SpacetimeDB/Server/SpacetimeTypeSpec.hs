{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoFieldSelectors #-}

-- NoFieldSelectors is enabled here on purpose: authors declare table types under
-- the project record convention, so the generic field-name derivation must still
-- recover names from the Generic metadata even when selectors are suppressed.
module SpacetimeDB.Server.SpacetimeTypeSpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Server.Schema (AlgType (..), Field (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import Test.Hspec

-- A table row declared as a plain Haskell record.
data Event = Event {who :: Text, at :: Int64}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (SpacetimeType)

-- A different shape (mixed scalar types) to exercise the generic derivation.
data Mixed = Mixed {flag :: Bool, count :: Word32, label :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (SpacetimeType)

spec :: Spec
spec = describe "SpacetimeType" $ do
  it "derives the AlgType product (names + field order) from a record" $
    algebraicType @Event
      `shouldBe` TProduct [Field (Just "who") TString, Field (Just "at") TI64]

  it "round-trips a record value through the derived BSATN codec" $ do
    let e = Event "alice" 42
    runExact decodeVal (runEncoder encodeVal e) `shouldBe` Right e

  it "derives and round-trips a mixed-type record" $ do
    let m = Mixed True 7 "hi"
    algebraicType @Mixed
      `shouldBe` TProduct
        [Field (Just "flag") TBool, Field (Just "count") TU32, Field (Just "label") TString]
    runExact decodeVal (runEncoder encodeVal m) `shouldBe` Right m
