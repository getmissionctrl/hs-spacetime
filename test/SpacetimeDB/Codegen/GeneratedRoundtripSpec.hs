{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Codegen.GeneratedRoundtripSpec (spec) where

import Generated
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import Test.Hspec

spec :: Spec
spec =
  it "generated Widget round-trips through decode . encode" $ do
    let w = Widget 42 "gadget" 7
    runExact decodeWidget (runEncoder encodeWidget w) `shouldBe` Right w
