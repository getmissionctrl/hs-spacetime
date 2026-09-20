{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module Module where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Int (Int16)
import Data.Word (Word8, Word16, Word32)
import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek, poke)

import SpacetimeDB.BSATN.Decoder (runExact, string)
import SpacetimeDB.BSATN.Encoder (encodeString, runEncoder)

-- Host imports (defined in cbits/spacetime_abi.c with wasm import attributes).
foreign import ccall unsafe "st_table_id_from_name"
  c_table_id_from_name :: Ptr Word8 -> CSize -> Ptr Word32 -> IO Word16
foreign import ccall unsafe "st_datastore_insert_bsatn"
  c_insert :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16
foreign import ccall unsafe "st_bytes_source_read"
  c_source_read :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Int16
foreign import ccall unsafe "st_bytes_sink_write"
  c_sink_write :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16

-- Golden schema BSATN (129 bytes), reproduced verbatim. Phase 2 replaces this
-- with a real RawModuleDefV10 emitter. Bytes generated from
-- phase0/golden/person.schema.bsatn via `xxd -i`.
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

-- Read all bytes from a source handle, growing as needed.
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

-- Write a full ByteString into a sink handle.
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
  case runExact string argBytes of
    Left _ -> pure 1  -- HOST_CALL_FAILURE
    Right name -> do
      tid <- lookupPersonId
      let row = runEncoder encodeString name  -- product {name} = bare string
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
