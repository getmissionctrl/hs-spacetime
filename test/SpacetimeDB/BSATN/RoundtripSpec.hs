{-# LANGUAGE ScopedTypeVariables #-}

module SpacetimeDB.BSATN.RoundtripSpec (spec) where

import Data.Int (Int64)
import Data.Word (Word64)
import Data.WideWord (Word128)
import Test.Hspec
import Test.QuickCheck
import SpacetimeDB.BSATN.Decoder
import SpacetimeDB.BSATN.Encoder

-- Build a wide value from 30-bit chunks so the high bytes are exercised
-- (QuickCheck's integral gen is 32-bit internally).
wideWord64 :: Gen Word64
wideWord64 = do
  hi <- choose (0, 2 ^ (30 :: Int) - 1) :: Gen Integer
  mid <- choose (0, 2 ^ (30 :: Int) - 1) :: Gen Integer
  lo <- choose (0, 2 ^ (30 :: Int) - 1) :: Gen Integer
  pure (fromInteger ((hi * 2 ^ (34 :: Int)) + (mid * 2 ^ (4 :: Int)) + lo))

boundaries64 :: [Word64]
boundaries64 = [0, 1, 2 ^ (63 :: Int), maxBound]

roundtrip :: (Eq a, Show a) => Encoder a -> Decoder a -> a -> Expectation
roundtrip enc dec x = runExact dec (runEncoder enc x) `shouldBe` Right x

spec :: Spec
spec = do
  describe "u64 round-trip" $ do
    it "hits boundaries" $ mapM_ (roundtrip encodeU64 u64) boundaries64
    it "holds for wide randoms" $ property $ forAll wideWord64 $ \w ->
      runExact u64 (runEncoder encodeU64 w) === Right w
  describe "i64 round-trip" $
    it "holds incl. -1" $ property $ \(i :: Int64) ->
      runExact i64 (runEncoder encodeI64 i) === Right i
  describe "u128 round-trip" $
    it "boundaries" $ mapM_ (roundtrip encodeU128 u128)
      [0, 1, 2 ^ (127 :: Int), maxBound :: Word128]
