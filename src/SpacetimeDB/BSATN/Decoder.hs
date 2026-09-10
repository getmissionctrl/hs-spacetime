{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SpacetimeDB.BSATN.Decoder
  ( DecodeError (..)
  , Decoder (..)
  , takeBytes
  , word8
  , success
  , sumD
  , u8, i8, u16, i16, u32, i32, u64, i64, u128, i128, u256, i256
  , f32, f64, bool
  , runExact
  , string, bytes, list, optional, decodeRows
  , result
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int8, Int16, Int32, Int64)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.WideWord (Int128, Int256, Word128, Word256)
import Data.Word (Word8, Word16, Word32, Word64)
import GHC.Float (castWord32ToFloat, castWord64ToDouble)

data DecodeError
  = UnexpectedEnd
  | InvalidBool Word8
  | InvalidUtf8
  | UnknownVariant Word8
  | Custom Text
  deriving (Eq, Show)

newtype Decoder a = Decoder { runDecoder :: ByteString -> Either DecodeError (a, ByteString) }

-- | Consume exactly @n@ bytes or fail.
takeBytes :: Int -> Decoder ByteString
takeBytes n = Decoder $ \bs ->
  if BS.length bs < n
    then Left UnexpectedEnd
    else Right (BS.splitAt n bs)

word8 :: Decoder Word8
word8 = Decoder $ \bs -> case BS.uncons bs of
  Nothing -> Left UnexpectedEnd
  Just (b, rest) -> Right (b, rest)

instance Functor Decoder where
  fmap f (Decoder d) = Decoder $ \bs -> case d bs of
    Left e -> Left e
    Right (a, rest) -> Right (f a, rest)

instance Applicative Decoder where
  pure x = Decoder $ \bs -> Right (x, bs)
  (Decoder df) <*> (Decoder da) = Decoder $ \bs -> case df bs of
    Left e -> Left e
    Right (f, rest) -> case da rest of
      Left e -> Left e
      Right (a, rest') -> Right (f a, rest')

instance Monad Decoder where
  (Decoder d) >>= f = Decoder $ \bs -> case d bs of
    Left e -> Left e
    Right (a, rest) -> runDecoder (f a) rest

-- | Yield a value, consuming nothing. Alias for 'pure' for parity with the skill.
success :: a -> Decoder a
success = pure

-- | Read a u8 tag, then run the payload decoder that @pick@ returns.
sumD :: (Word8 -> Either DecodeError (Decoder a)) -> Decoder a
sumD pick = do
  tag <- word8
  case pick tag of
    Left e -> Decoder (const (Left e))
    Right d -> d

-- | Assemble an unsigned little-endian integer of @n@ bytes into an Integer,
-- then narrow with fromInteger at the call site.
leUnsigned :: Int -> Decoder Integer
leUnsigned n = do
  bs <- takeBytes n
  pure $ foldr (\b acc -> acc `shiftL` 8 .|. fromIntegral b) 0 (BS.unpack bs)

u8 :: Decoder Word8
u8 = word8
u16 :: Decoder Word16
u16 = fromInteger <$> leUnsigned 2
u32 :: Decoder Word32
u32 = fromInteger <$> leUnsigned 4
u64 :: Decoder Word64
u64 = fromInteger <$> leUnsigned 8
u128 :: Decoder Word128
u128 = fromInteger <$> leUnsigned 16
u256 :: Decoder Word256
u256 = fromInteger <$> leUnsigned 32

i8 :: Decoder Int8
i8 = fromIntegral <$> word8
i16 :: Decoder Int16
i16 = fromIntegral <$> u16
i32 :: Decoder Int32
i32 = fromIntegral <$> u32
i64 :: Decoder Int64
i64 = fromIntegral <$> u64
i128 :: Decoder Int128
i128 = fromIntegral <$> u128
i256 :: Decoder Int256
i256 = fromIntegral <$> u256

f32 :: Decoder Float
f32 = castWord32ToFloat <$> u32

f64 :: Decoder Double
f64 = castWord64ToDouble <$> u64

bool :: Decoder Bool
bool = do
  b <- word8
  case b of
    0 -> pure False
    1 -> pure True
    _ -> Decoder (const (Left (InvalidBool b)))

-- | Run a decoder and require every byte consumed.
runExact :: Decoder a -> ByteString -> Either DecodeError a
runExact d bs = case runDecoder d bs of
  Left e -> Left e
  Right (a, rest)
    | BS.null rest -> Right a
    | otherwise -> Left (Custom "trailing bytes")

bytes :: Decoder ByteString
bytes = do
  n <- u32
  takeBytes (fromIntegral n)

string :: Decoder Text
string = do
  raw <- bytes
  case TE.decodeUtf8' raw of
    Left _ -> Decoder (const (Left InvalidUtf8))
    Right t -> pure t

list :: Decoder a -> Decoder [a]
list elemD = do
  n <- u32
  go (fromIntegral n) []
  where
    go 0 acc = pure (reverse acc)
    go k acc = do x <- elemD; go (k - 1 :: Int) (x : acc)

-- | Option: tag 0 = some, tag 1 = none.
optional :: Decoder a -> Decoder (Maybe a)
optional someD = sumD $ \t -> case t of
  0 -> Right (Just <$> someD)
  1 -> Right (pure Nothing)
  _ -> Left (UnknownVariant t)

-- | runExact each row of a split row list, reporting the index that failed.
decodeRows :: Decoder a -> [ByteString] -> Either (Int, DecodeError) [a]
decodeRows d = go 0 []
  where
    go _ acc [] = Right (reverse acc)
    go i acc (r : rs) = case runExact d r of
      Left e -> Left (i, e)
      Right a -> go (i + 1) (a : acc) rs

-- | Result: tag 0 = ok, tag 1 = err.
result :: Decoder e -> Decoder a -> Decoder (Either e a)
result errD okD = sumD $ \t -> case t of
  0 -> Right (Right <$> okD)
  1 -> Right (Left <$> errD)
  _ -> Left (UnknownVariant t)
