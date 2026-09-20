{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Server.ABI
  ( ffiBackend
  , runDescribe
  , runCallReducer
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Int (Int16)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek, poke)
import SpacetimeDB.Server.Dispatch (describeBytes, dispatchReducer, mkContext)
import SpacetimeDB.Server.Internal

foreign import ccall unsafe "shim_table_id_from_name"
  c_table_id_from_name :: Ptr Word8 -> CSize -> Ptr Word32 -> IO Word16
foreign import ccall unsafe "shim_datastore_insert_bsatn"
  c_insert :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16
foreign import ccall unsafe "shim_bytes_source_read"
  c_source_read :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Int16
foreign import ccall unsafe "shim_bytes_sink_write"
  c_sink_write :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Word16
foreign import ccall unsafe "shim_console_log"
  c_console_log :: Word8 -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Word32 -> Ptr Word8 -> CSize -> IO ()
foreign import ccall unsafe "shim_datastore_table_scan_bsatn"
  c_scan :: Word32 -> Ptr Word32 -> IO Word16
foreign import ccall unsafe "shim_row_iter_bsatn_advance"
  c_iter_advance :: Word32 -> Ptr Word8 -> Ptr CSize -> IO Int16
foreign import ccall unsafe "shim_row_iter_bsatn_close"
  c_iter_close :: Word32 -> IO Word16
foreign import ccall unsafe "shim_datastore_delete_all_by_eq_bsatn"
  c_delete_eq :: Word32 -> Ptr Word8 -> CSize -> Ptr Word32 -> IO Word16

errnoText :: Word16 -> Text
errnoText e = "spacetime errno " <> T.pack (show e)

okOr :: Word16 -> a -> Either Text a
okOr 0 a = Right a
okOr e _ = Left (errnoText e)

-- Read one host stream (source) fully: harvest bytes on EVERY read; continue
-- only while the host returns 0 (more may remain). Stop on -1 (exhausted) OR on
-- any positive errno. The latter is essential for no-arg reducers: the host
-- passes the INVALID source id 0, and 'bytes_source_read' on it returns
-- NO_SUCH_BYTES (a positive errno) forever — stopping only on -1 would loop.
readSource :: Word32 -> IO BS.ByteString
readSource 0 = pure BS.empty -- BytesSource::INVALID (0): the reducer has no args
readSource src = go BS.empty
 where
  cap = 4096
  go acc = allocaBytes cap $ \buf -> alloca $ \lenp -> do
    poke lenp (fromIntegral cap)
    rc <- c_source_read src buf lenp
    n <- peek lenp
    chunk <- BS.packCStringLen (castPtr buf, fromIntegral n)
    let acc' = acc <> chunk
    if rc == 0 then go acc' else pure acc' -- rc == -1 (done) or rc > 0 (errno): stop

writeSink :: Word32 -> BS.ByteString -> IO ()
writeSink sink payload =
  BSU.unsafeUseAsCStringLen payload $ \(ptr, len) -> alloca $ \lenp -> do
    poke lenp (fromIntegral len)
    _ <- c_sink_write sink (castPtr ptr) lenp
    pure ()

-- BSATN row-iterator errno: the buffer was too small for the next row.
bufferTooSmall :: Int16
bufferTooSmall = 11

-- Drain a row iterator into the host's raw concatenated BSATN row batch,
-- following the documented row_iter_bsatn_advance protocol:
--   0                = a batch was written to the buffer; more rows may follow.
--   -1               = the final batch was written AND the iterator is destroyed
--                      (so we must NOT call close afterwards).
--   BUFFER_TOO_SMALL = nothing was written; buf_len holds the size the next row
--                      needs, so grow the buffer and retry.
-- The concatenated bytes are split into individual rows upstream (Server.scan),
-- which knows the row type.
drainIter :: Word32 -> IO (Either Text BS.ByteString)
drainIter it = go BS.empty 4096
 where
  go acc cap = allocaBytes cap $ \buf -> alloca $ \lenp -> do
    poke lenp (fromIntegral cap)
    rc <- c_iter_advance it buf lenp
    n <- fmap fromIntegral (peek lenp)
    if rc == bufferTooSmall
      then go acc (max cap n) -- grow to the required size, retry
      else
        if rc == 0 || rc == (-1)
          then do
            chunk <- BS.packCStringLen (castPtr buf, n)
            let acc' = acc <> chunk
            if rc == (-1)
              then pure (Right acc') -- iterator already destroyed by host
              else
                if n == 0
                  then c_iter_close it >> pure (Right acc')
                  else go acc' cap
          else pure (Left (errnoText (fromIntegral rc)))

ffiBackend :: Backend
ffiBackend =
  Backend
    { tableId = \name ->
        BSU.unsafeUseAsCStringLen (TE.encodeUtf8 name) $ \(p, l) -> alloca $ \o -> do
          e <- c_table_id_from_name (castPtr p) (fromIntegral l) o
          v <- peek o
          pure (okOr e (TableId v))
    , insert = \(TableId t) row ->
        BSU.unsafeUseAsCStringLen row $ \(p, l) -> alloca $ \lenp -> do
          poke lenp (fromIntegral l)
          e <- c_insert t (castPtr p) lenp
          pure (okOr e ())
    , scan = \(TableId t) -> alloca $ \o -> do
        e <- c_scan t o
        if e /= 0 then pure (Left (errnoText e)) else peek o >>= drainIter
    , delete = \(TableId t) row ->
        -- datastore_delete_all_by_eq_bsatn decodes `rel` as a BSATN Vec<ProductValue>
        -- (a row *list*), so wrap the single row as a 1-element vec: [u32 count=1][row].
        let rel = BS.pack [1, 0, 0, 0] <> row
         in BSU.unsafeUseAsCStringLen rel $ \(p, l) -> alloca $ \o -> do
              e <- c_delete_eq t (castPtr p) (fromIntegral l) o
              pure (okOr e ())
    , log = \msg ->
        BSU.unsafeUseAsCStringLen (TE.encodeUtf8 msg) $ \(p, l) ->
          c_console_log 3 (castPtr p) 0 (castPtr p) 0 0 (castPtr p) (fromIntegral l)
    }

runDescribe :: ModuleDef -> Word32 -> IO ()
runDescribe md sink = writeSink sink (describeBytes md)

runCallReducer
  :: ModuleDef
  -> Word32
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word32
  -> Word32
  -> IO Int16
runCallReducer md rid s0 s1 s2 s3 c0 c1 ts argsSrc errSink = do
  let ctx = mkContext s0 s1 s2 s3 c0 c1 ts
  args <- readSource argsSrc
  res <- dispatchReducer md (fromIntegral rid) ctx args ffiBackend
  case res of
    Right () -> pure 0
    Left msg -> do writeSink errSink (TE.encodeUtf8 msg); pure 1
