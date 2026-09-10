module Main (main) where

import Test.Hspec (hspec, describe)
import qualified SpacetimeDB.BSATN.DecoderSpec
import qualified SpacetimeDB.BSATN.EncoderSpec
import qualified SpacetimeDB.BSATN.RoundtripSpec
import qualified SpacetimeDB.BSATN.TypesSpec
import qualified SpacetimeDB.Protocol.RowListSpec
import qualified SpacetimeDB.Protocol.MessagesSpec
import qualified SpacetimeDB.Protocol.FrameSpec

main :: IO ()
main = hspec $ do
  describe "SpacetimeDB.BSATN.Decoder" SpacetimeDB.BSATN.DecoderSpec.spec
  describe "SpacetimeDB.BSATN.Encoder" SpacetimeDB.BSATN.EncoderSpec.spec
  describe "SpacetimeDB.BSATN.Roundtrip" SpacetimeDB.BSATN.RoundtripSpec.spec
  describe "SpacetimeDB.BSATN.Types" SpacetimeDB.BSATN.TypesSpec.spec
  describe "SpacetimeDB.Protocol.RowList" SpacetimeDB.Protocol.RowListSpec.spec
  describe "SpacetimeDB.Protocol.Messages" SpacetimeDB.Protocol.MessagesSpec.spec
  describe "SpacetimeDB.Protocol.Frame" SpacetimeDB.Protocol.FrameSpec.spec
