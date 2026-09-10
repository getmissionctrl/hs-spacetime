module SpacetimeDB.Protocol.RowListSpec (spec) where

import qualified Data.ByteString as BS
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.Protocol.RowList
import Test.Hspec

spec :: Spec
spec = do
  describe "splitRows" $ do
    it "FixedSize chunks evenly" $
      splitRows (FixedSize 2) (BS.pack [1, 2, 3, 4]) `shouldBe` [BS.pack [1, 2], BS.pack [3, 4]]
    it "FixedSize 0 means no rows" $
      splitRows (FixedSize 0) BS.empty `shouldBe` []
    it "RowOffsets slices at offsets, last runs to end" $
      splitRows (RowOffsets [0, 2]) (BS.pack [1, 2, 3, 4, 5]) `shouldBe` [BS.pack [1, 2], BS.pack [3, 4, 5]]
    it "RowOffsets empty means no rows" $
      splitRows (RowOffsets []) (BS.pack [1, 2]) `shouldBe` []
  describe "decodeRowList" $
    it "reads hint + bytes and splits" $
      -- FixedSize(2) hint = sum tag 0, u16 2; then bytes: u32 len 4 + [1,2,3,4]
      runExact decodeRowList (BS.pack [0, 2, 0, 4, 0, 0, 0, 1, 2, 3, 4])
        `shouldBe` Right [BS.pack [1, 2], BS.pack [3, 4]]
