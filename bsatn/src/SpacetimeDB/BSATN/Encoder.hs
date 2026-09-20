module SpacetimeDB.BSATN.Encoder
  ( Encoder
  , runEncoder
  , encodeU8
  , encodeU16
  , encodeU32
  , encodeU64
  , encodeU128
  , encodeU256
  , encodeI8
  , encodeI16
  , encodeI32
  , encodeI64
  , encodeI128
  , encodeI256
  , encodeF32
  , encodeF64
  , encodeBool
  , encodeString
  , encodeBytes
  , concatE
  , contramap
  , encodeSum
  , encodeList
  , encodeOptional
  , encodeResult
  , encodeListOf
  , encodeOptionalOf
  ) where

import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.WideWord (Int128, Int256, Word128, Word256)
import Data.Word (Word16, Word32, Word64, Word8)

type Encoder a = a -> B.Builder

runEncoder :: Encoder a -> a -> ByteString
runEncoder e = BL.toStrict . B.toLazyByteString . e

encodeU8 :: Encoder Word8
encodeU8 = B.word8
encodeU16 :: Encoder Word16
encodeU16 = B.word16LE
encodeU32 :: Encoder Word32
encodeU32 = B.word32LE
encodeU64 :: Encoder Word64
encodeU64 = B.word64LE
encodeI8 :: Encoder Int8
encodeI8 = B.int8
encodeI16 :: Encoder Int16
encodeI16 = B.int16LE
encodeI32 :: Encoder Int32
encodeI32 = B.int32LE
encodeI64 :: Encoder Int64
encodeI64 = B.int64LE
encodeF32 :: Encoder Float
encodeF32 = B.floatLE
encodeF64 :: Encoder Double
encodeF64 = B.doubleLE

-- Wide words: emit LE bytes by repeated shift.
leBytesOf :: Int -> Integer -> B.Builder
leBytesOf n = go n
 where
  go 0 _ = mempty
  go k v = B.word8 (fromIntegral (v .&. 0xFF)) <> go (k - 1) (v `shiftR` 8)

encodeU128 :: Encoder Word128
encodeU128 = leBytesOf 16 . toInteger
encodeU256 :: Encoder Word256
encodeU256 = leBytesOf 32 . toInteger
encodeI128 :: Encoder Int128
encodeI128 = leBytesOf 16 . toIntegerMod (16 * 8)
encodeI256 :: Encoder Int256
encodeI256 = leBytesOf 32 . toIntegerMod (32 * 8)

-- two's-complement wrap into an unsigned Integer of the given bit width
toIntegerMod :: (Integral a) => Int -> a -> Integer
toIntegerMod bits x = toInteger x `mod` (2 ^ bits)

encodeBool :: Encoder Bool
encodeBool b = B.word8 (if b then 1 else 0)

encodeBytes :: Encoder ByteString
encodeBytes bs = B.word32LE (fromIntegral (BS.length bs)) <> B.byteString bs

encodeString :: Encoder Text
encodeString = encodeBytes . TE.encodeUtf8

concatE :: [B.Builder] -> B.Builder
concatE = mconcat

contramap :: (b -> a) -> Encoder a -> Encoder b
contramap f enc = enc . f

encodeSum :: Word8 -> B.Builder -> B.Builder
encodeSum tag payload = B.word8 tag <> payload

encodeList :: [a] -> Encoder a -> B.Builder
encodeList xs enc = B.word32LE (fromIntegral (length xs)) <> mconcat (map enc xs)

encodeListOf :: Encoder a -> Encoder [a]
encodeListOf enc xs = encodeList xs enc

encodeOptional :: Maybe a -> Encoder a -> B.Builder
encodeOptional Nothing _ = B.word8 1
encodeOptional (Just x) enc = B.word8 0 <> enc x

encodeOptionalOf :: Encoder a -> Encoder (Maybe a)
encodeOptionalOf enc mx = encodeOptional mx enc

encodeResult :: Either e a -> Encoder e -> Encoder a -> B.Builder
encodeResult (Right a) _ encA = B.word8 0 <> encA a
encodeResult (Left e) encE _ = B.word8 1 <> encE e
