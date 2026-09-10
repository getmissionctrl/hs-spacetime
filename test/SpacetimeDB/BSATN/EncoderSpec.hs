{-# LANGUAGE ScopedTypeVariables #-}

module SpacetimeDB.BSATN.EncoderSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.BSATN.Encoder

spec :: Spec
spec = do
  it "encodeU32 is little-endian" $
    runEncoder encodeU32 1 `shouldBe` BS.pack [1, 0, 0, 0]
  it "encodeString is u32-len + utf8" $
    runEncoder encodeString (T.pack "abc") `shouldBe` BS.pack [3, 0, 0, 0, 0x61, 0x62, 0x63]
  it "encodeBool" $ runEncoder encodeBool True `shouldBe` BS.pack [1]
  it "concatE lays fields end to end" $
    runEncoder (\(_ :: ()) -> concatE [encodeU8 1, encodeU16 2]) () `shouldBe` BS.pack [1, 2, 0]
  it "encodeOptional some=0" $
    runEncoder (\x -> encodeOptional x encodeU8) (Just 7) `shouldBe` BS.pack [0, 7]
  it "encodeOptional none=1" $
    runEncoder (\x -> encodeOptional x encodeU8) Nothing `shouldBe` BS.pack [1]
  it "encodeList is u32-count + elems" $
    runEncoder (\xs -> encodeList xs encodeU8) [5, 6] `shouldBe` BS.pack [2, 0, 0, 0, 5, 6]
  it "encodeSum writes tag then payload" $
    runEncoder (\() -> encodeSum 2 (encodeU8 9)) () `shouldBe` BS.pack [2, 9]
