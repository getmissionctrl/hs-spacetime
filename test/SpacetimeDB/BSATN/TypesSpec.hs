module SpacetimeDB.BSATN.TypesSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.BSATN.Types
import Test.Hspec

spec :: Spec
spec = do
  it "Identity is 32 LE bytes, round-trips" $ do
    let bytes32 = BS.pack (1 : replicate 31 0)
    runExact decodeIdentity bytes32 `shouldBe` Right (identityFromInteger 1)
    runEncoder encodeIdentity (identityFromInteger 1) `shouldBe` bytes32
  it "Identity renders as 64 lowercase hex, zero-padded" $
    identityToHex (identityFromInteger 1)
      `shouldBe` T.pack ("000000000000000000000000000000000000000000000000000000000000000" ++ "1")
  it "Timestamp is i64 micros" $
    runExact decodeTimestamp (BS.pack (replicate 8 0)) `shouldBe` Right (Timestamp 0)
