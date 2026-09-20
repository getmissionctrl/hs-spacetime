{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module Module where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Unsafe as BSU
import Data.Int (Int16)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word8, Word16, Word32)
import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek, poke)

-- Call the C shim wrappers (cbits/spacetime_abi.c), which forward to the real
-- wasm host imports in module "spacetime_10.0". The Haskell FFI always emits
-- imports into "env", so it cannot reference the host imports directly.
foreign import ccall unsafe "shim_table_id_from_name"
  c_table_id_from_name :: Ptr Word8 -> CSize -> Ptr Word32 -> IO Word16
foreign import ccall unsafe "shim_datastore_insert_bsatn"
  c_insert :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16
foreign import ccall unsafe "shim_bytes_source_read"
  c_source_read :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Int16
foreign import ccall unsafe "shim_bytes_sink_write"
  c_sink_write :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16

-- Golden schema BSATN (129 bytes), reproduced verbatim.
schemaBytes :: ByteString
schemaBytes = BS.pack
  [ 0x02, 0x05, 0x00, 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00
  , 0x00, 0x00, 0x61, 0x64, 0x64, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00
  , 0x00, 0x00, 0x6e, 0x61, 0x6d, 0x65, 0x04, 0x01, 0x02, 0x00, 0x00, 0x00
  , 0x00, 0x04, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00
  , 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x6e, 0x61
  , 0x6d, 0x65, 0x04, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x06, 0x00, 0x00, 0x00, 0x50, 0x65, 0x72, 0x73, 0x6f, 0x6e, 0x00, 0x00
  , 0x00, 0x00, 0x01, 0x02, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00
  , 0x70, 0x65, 0x72, 0x73, 0x6f, 0x6e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  , 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  ]

-- Inline BSATN string codec (boot packages only; Phase 0 avoids wide-word).
encodeStringBsatn :: Text -> ByteString
encodeStringBsatn t =
  let utf8 = TE.encodeUtf8 t
   in BL.toStrict . BB.toLazyByteString $
        BB.word32LE (fromIntegral (BS.length utf8)) <> BB.byteString utf8

-- Decode a bare BSATN string, requiring ALL input consumed (runExact-style).
decodeStringBsatnExact :: ByteString -> Maybe Text
decodeStringBsatnExact bs
  | BS.length bs < 4 = Nothing
  | otherwise =
      let (lenB, rest) = BS.splitAt 4 bs
          len = fromIntegral (leWord32 lenB)
       in if BS.length rest == len
            then either (const Nothing) Just (TE.decodeUtf8' rest)
            else Nothing

leWord32 :: ByteString -> Word32
leWord32 b =
  fromIntegral (BS.index b 0)
    .|. (fromIntegral (BS.index b 1) `shiftL` 8)
    .|. (fromIntegral (BS.index b 2) `shiftL` 16)
    .|. (fromIntegral (BS.index b 3) `shiftL` 24)

readSource :: Word32 -> IO ByteString
readSource src = go BS.empty
  where
    cap = 4096
    go acc = allocaBytes cap $ \buf -> alloca $ \lenp -> do
      poke lenp (fromIntegral cap)
      rc <- c_source_read src buf lenp
      if rc == (-1)
        then pure acc
        else do
          n <- peek lenp
          chunk <- BS.packCStringLen (castPtr buf, fromIntegral n)
          if fromIntegral n < cap then pure (acc <> chunk) else go (acc <> chunk)

writeSink :: Word32 -> ByteString -> IO ()
writeSink sink payload =
  BSU.unsafeUseAsCStringLen payload $ \(ptr, len) -> alloca $ \lenp -> do
    poke lenp (fromIntegral len)
    _ <- c_sink_write sink (castPtr ptr) lenp
    pure ()

foreign export ccall hs_describe :: Word32 -> IO ()
hs_describe :: Word32 -> IO ()
hs_describe sink = writeSink sink schemaBytes

foreign export ccall hs_call_reducer :: Word32 -> Word32 -> IO Int16
hs_call_reducer :: Word32 -> Word32 -> IO Int16
hs_call_reducer argsSrc _errSink = do
  argBytes <- readSource argsSrc
  case decodeStringBsatnExact argBytes of
    Nothing -> pure 1
    Just name -> do
      tid <- lookupPersonId
      let row = encodeStringBsatn name
      insertRow tid row
      pure 0

lookupPersonId :: IO Word32
lookupPersonId =
  BSU.unsafeUseAsCStringLen "person" $ \(ptr, len) -> alloca $ \outp -> do
    _ <- c_table_id_from_name (castPtr ptr) (fromIntegral len) outp
    peek outp

insertRow :: Word32 -> ByteString -> IO ()
insertRow tid row =
  BSU.unsafeUseAsCStringLen row $ \(ptr, len) -> alloca $ \lenp -> do
    poke lenp (fromIntegral len)
    _ <- c_insert tid (castPtr ptr) lenp
    pure ()
