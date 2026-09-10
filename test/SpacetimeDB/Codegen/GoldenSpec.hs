module SpacetimeDB.Codegen.GoldenSpec (spec) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.IO as TIO
import SpacetimeDB.Codegen
import SpacetimeDB.Codegen.Schema
import Test.Hspec

spec :: Spec
spec =
  it "sample fixture matches the committed golden" $ do
    raw <- BL.readFile "test/fixtures/sample.schema.json"
    golden <- TIO.readFile "test/golden/Generated.hs"
    case parseModule raw of
      Left e -> expectationFailure e
      Right m -> generate False (computeNamedDropped m) `shouldBe` Right golden
