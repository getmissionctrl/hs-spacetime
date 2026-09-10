{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SpacetimeDB.BSATN.DecoderSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Int (Int8)
import Data.Word (Word16, Word32, Word64)
import Data.WideWord (Word128)
import Test.Hspec
import SpacetimeDB.BSATN.Decoder

spec :: Spec
spec = do
  describe "takeBytes" $ do
    it "splits off n bytes and keeps the rest" $
      runDecoder (takeBytes 2) (BS.pack [1, 2, 3]) `shouldBe` Right (BS.pack [1, 2], BS.pack [3])
    it "fails with UnexpectedEnd when short" $
      runDecoder (takeBytes 4) (BS.pack [1, 2]) `shouldBe` Left UnexpectedEnd
  describe "word8" $
    it "reads one byte" $
      runDecoder word8 (BS.pack [7, 8]) `shouldBe` Right (7, BS.pack [8])
  describe "combinators" $ do
    it "success consumes nothing" $
      runDecoder (success 'x') (BS.pack [1]) `shouldBe` Right ('x', BS.pack [1])
    it "fmap transforms the value" $
      runDecoder (fmap (+ 1) word8) (BS.pack [5]) `shouldBe` Right (6, BS.empty)
    it "monadic bind threads the remainder" $ do
      let d = do a <- word8; b <- word8; pure (a, b)
      runDecoder d (BS.pack [1, 2, 3]) `shouldBe` Right ((1, 2), BS.pack [3])
    it "sumD dispatches on the tag" $ do
      let d = sumD $ \t -> case t of
                0 -> Right (success "zero")
                1 -> Right (fmap show word8)
                _ -> Left (UnknownVariant t)
      runDecoder d (BS.pack [1, 9]) `shouldBe` Right ("9", BS.empty)
    it "sumD reports unknown variants" $ do
      let d = sumD $ \t -> if t == 0 then Right (success ()) else Left (UnknownVariant t)
      runDecoder d (BS.pack [3]) `shouldBe` Left (UnknownVariant 3)
  describe "integers (LE) and runExact" $ do
    it "u16 reads little-endian" $
      runExact u16 (BS.pack [0x34, 0x12]) `shouldBe` Right (0x1234 :: Word16)
    it "u32 reads little-endian" $
      runExact u32 (BS.pack [1, 0, 0, 0]) `shouldBe` Right (1 :: Word32)
    it "i8 -1 is all-ones" $
      runExact i8 (BS.pack [0xFF]) `shouldBe` Right (-1 :: Int8)
    it "u64 max" $
      runExact u64 (BS.pack [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) `shouldBe` Right (maxBound :: Word64)
    it "u128 round value" $
      runExact u128 (BS.pack (1 : replicate 15 0)) `shouldBe` Right (1 :: Word128)
    it "runExact rejects trailing bytes" $
      runExact u16 (BS.pack [1, 0, 9]) `shouldBe` Left (Custom "trailing bytes")
  describe "string/bytes/list/optional/decodeRows" $ do
    it "string is u32-length + utf8" $
      runExact string (BS.pack [3, 0, 0, 0, 0x61, 0x62, 0x63]) `shouldBe` Right ("abc" :: T.Text)
    it "rejects invalid utf8" $
      runExact string (BS.pack [1, 0, 0, 0, 0xFF]) `shouldBe` Left InvalidUtf8
    it "bytes is u32-length + raw" $
      runExact bytes (BS.pack [2, 0, 0, 0, 9, 9]) `shouldBe` Right (BS.pack [9, 9])
    it "list is u32-count + elems" $
      runExact (list u8) (BS.pack [2, 0, 0, 0, 5, 6]) `shouldBe` Right [5, 6]
    it "optional some=0" $
      runExact (optional u8) (BS.pack [0, 7]) `shouldBe` Right (Just 7)
    it "optional none=1" $
      runExact (optional u8) (BS.pack [1]) `shouldBe` Right Nothing
    it "decodeRows reports the failing index" $
      decodeRows u16 [BS.pack [1, 0], BS.pack [2]] `shouldBe` Left (1, UnexpectedEnd)
    it "decodeRows returns all rows" $
      decodeRows u16 [BS.pack [1, 0], BS.pack [2, 0]] `shouldBe` Right [1, 2]
  describe "result" $ do
    it "ok=0" $ runExact (result string u8) (BS.pack [0, 5]) `shouldBe` Right (Right 5)
    it "err=1" $
      runExact (result string u8) (BS.pack [1, 1, 0, 0, 0, 0x61]) `shouldBe` Right (Left ("a" :: T.Text))
