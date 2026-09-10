module Main (main) where

import Test.Hspec (hspec, describe)
import qualified SpacetimeDB.BSATN.DecoderSpec
import qualified SpacetimeDB.BSATN.EncoderSpec
import qualified SpacetimeDB.BSATN.RoundtripSpec
import qualified SpacetimeDB.BSATN.TypesSpec

main :: IO ()
main = hspec $ do
  describe "SpacetimeDB.BSATN.Decoder" SpacetimeDB.BSATN.DecoderSpec.spec
  describe "SpacetimeDB.BSATN.Encoder" SpacetimeDB.BSATN.EncoderSpec.spec
  describe "SpacetimeDB.BSATN.Roundtrip" SpacetimeDB.BSATN.RoundtripSpec.spec
  describe "SpacetimeDB.BSATN.Types" SpacetimeDB.BSATN.TypesSpec.spec
