{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module PersonModule where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int16, Int64)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word32, Word64)
import SpacetimeDB.BSATN.Decoder (i64, string, success, u32)
import SpacetimeDB.BSATN.Types (Timestamp (..))
import SpacetimeDB.Server
import SpacetimeDB.Server.ABI (runCallReducer, runDescribe)

-- Reducer schema captured from the Rust 'event' fixture (196 bytes). The host
-- assigns reducer ids by this schema's (alphabetical) array order:
--   0 = delete_all, 1 = record, 2 = record_n
-- so 'theModule' below lists its reducers in that exact order.
eventSchema :: ByteString
eventSchema =
  BS.pack
    [ 2
    , 5
    , 0
    , 0
    , 0
    , 3
    , 3
    , 0
    , 0
    , 0
    , 10
    , 0
    , 0
    , 0
    , 100
    , 101
    , 108
    , 101
    , 116
    , 101
    , 95
    , 97
    , 108
    , 108
    , 0
    , 0
    , 0
    , 0
    , 1
    , 2
    , 0
    , 0
    , 0
    , 0
    , 4
    , 6
    , 0
    , 0
    , 0
    , 114
    , 101
    , 99
    , 111
    , 114
    , 100
    , 1
    , 0
    , 0
    , 0
    , 0
    , 4
    , 0
    , 0
    , 0
    , 110
    , 111
    , 116
    , 101
    , 4
    , 1
    , 2
    , 0
    , 0
    , 0
    , 0
    , 4
    , 8
    , 0
    , 0
    , 0
    , 114
    , 101
    , 99
    , 111
    , 114
    , 100
    , 95
    , 110
    , 1
    , 0
    , 0
    , 0
    , 0
    , 5
    , 0
    , 0
    , 0
    , 99
    , 111
    , 117
    , 110
    , 116
    , 11
    , 1
    , 2
    , 0
    , 0
    , 0
    , 0
    , 4
    , 10
    , 0
    , 0
    , 0
    , 0
    , 0
    , 1
    , 0
    , 0
    , 0
    , 2
    , 2
    , 0
    , 0
    , 0
    , 0
    , 3
    , 0
    , 0
    , 0
    , 119
    , 104
    , 111
    , 4
    , 0
    , 2
    , 0
    , 0
    , 0
    , 97
    , 116
    , 12
    , 1
    , 1
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 5
    , 0
    , 0
    , 0
    , 69
    , 118
    , 101
    , 110
    , 116
    , 0
    , 0
    , 0
    , 0
    , 1
    , 2
    , 1
    , 0
    , 0
    , 0
    , 5
    , 0
    , 0
    , 0
    , 101
    , 118
    , 101
    , 110
    , 116
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    , 1
    , 0
    , 0
    , 0
    , 0
    , 0
    , 0
    ]

-- Encode an Event{who::Text, at::Int64} row as a BSATN product (bare concat).
encodeEvent :: Text -> Int64 -> ByteString
encodeEvent who at =
  BL.toStrict . BB.toLazyByteString $
    BB.word32LE (fromIntegral (BS.length (TE.encodeUtf8 who)))
      <> BB.byteString (TE.encodeUtf8 who)
      <> BB.int64LE at

theModule :: ModuleDef
theModule =
  ModuleDef
    eventSchema
    [ reducer (success ()) $ \() -> do
        -- reducer 0: delete_all()
        t <- tableId "event"
        -- The row decoder (who :: String, at :: i64) is used only to find each
        -- row's byte boundary so we can delete it by its exact bytes.
        rows <- scan (string *> i64) t
        mapM_ (delete t) rows
    , reducer string $ \note -> do
        -- reducer 1: record(note)
        ctx <- ask
        let Timestamp micros = ctx.timestamp
        t <- tableId "event"
        insert t (encodeEvent note micros)
    , reducer u32 $ \count -> do
        -- reducer 2: record_n(count)
        if count == 0
          then throwError "count must be positive"
          else do t <- tableId "event"; insert t (encodeEvent "n" (fromIntegral count))
    ]

foreign export ccall hs_describe :: Word32 -> IO ()
hs_describe :: Word32 -> IO ()
hs_describe = runDescribe theModule

foreign export ccall
  hs_call_reducer
    :: Word32
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
hs_call_reducer
  :: Word32
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
hs_call_reducer = runCallReducer theModule
