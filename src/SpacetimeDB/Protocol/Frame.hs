{-# LANGUAGE ScopedTypeVariables #-}

module SpacetimeDB.Protocol.Frame
  ( FrameError (..)
  , decodeFrame
  ) where

import qualified Codec.Compression.Brotli as Brotli
import qualified Codec.Compression.GZip as GZip
import Control.Exception (SomeException, evaluate, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word8)
import SpacetimeDB.BSATN.Decoder (DecodeError, runExact)
import SpacetimeDB.Protocol.Messages (ServerMessage, decodeServerMessage)
import System.IO.Unsafe (unsafePerformIO)

data FrameError
  = EmptyFrame
  | UnsupportedCompression Word8
  | BrotliFailed
  | GzipFailed
  | Bsatn DecodeError
  deriving (Eq, Show)

decodeFrame :: ByteString -> Either FrameError ServerMessage
decodeFrame frame = case BS.uncons frame of
  Nothing -> Left EmptyFrame
  Just (tag, payload) -> do
    raw <- inflate tag payload
    case runExact decodeServerMessage raw of
      Left e -> Left (Bsatn e)
      Right m -> Right m

inflate :: Word8 -> ByteString -> Either FrameError ByteString
inflate 0 p = Right p
inflate 1 p = maybe (Left BrotliFailed) Right (safeLazy (Brotli.decompress (BL.fromStrict p)))
inflate 2 p = maybe (Left GzipFailed) Right (safeLazy (GZip.decompress (BL.fromStrict p)))
inflate t _ = Left (UnsupportedCompression t)

-- Decompressors throw on malformed input; force strictly and catch.
safeLazy :: BL.ByteString -> Maybe ByteString
safeLazy lbs = unsafePerformIO $ do
  r <- try (evaluate (BL.toStrict lbs)) :: IO (Either SomeException ByteString)
  pure (either (const Nothing) Just r)
{-# NOINLINE safeLazy #-}
