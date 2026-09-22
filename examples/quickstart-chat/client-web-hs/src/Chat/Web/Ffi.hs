{-# LANGUAGE ForeignFunctionInterface #-}

module Chat.Web.Ffi
  ( hs_subscribe
  , hs_on_frame
  , hs_send_message
  , hs_set_name
  ) where

import qualified Data.ByteString as BS
import Data.IORef
import qualified Data.Text as T
import Data.Word (Word32)
import System.IO.Unsafe (unsafePerformIO)

import GHC.Wasm.Prim

import Chat (App (..), SendMessageArgs (..), SetNameArgs (..), app)
import Chat.Web.Core
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Protocol.Messages (encodeSubscribe)
import SpacetimeDB.Server.Reducer (reducerName)
import SpacetimeDB.Server.Table (tableName)

-- Global single-threaded browser runtime state, persisted across export calls
-- by the wasm reactor.
modelRef :: IORef WebModel
modelRef = unsafePerformIO (newIORef emptyModel)
{-# NOINLINE modelRef #-}

ridRef :: IORef Word32
ridRef = unsafePerformIO (newIORef 100)
{-# NOINLINE ridRef #-}

nextRid :: IO Word32
nextRid = atomicModifyIORef' ridRef (\r -> (r + 1, r))

-- Synchronous JS<->wasm marshalling. `unsafe` => no RTS re-entry / no promise.
foreign import javascript unsafe "$1.length"
  js_len :: JSVal -> IO Int
foreign import javascript unsafe "$1[$2]"
  js_idx :: JSVal -> Int -> IO Int
foreign import javascript unsafe "new Uint8Array($1)"
  js_newBytes :: Int -> IO JSVal
foreign import javascript unsafe "$1[$2] = $3"
  js_setByte :: JSVal -> Int -> Int -> IO ()

fromJSBytes :: JSVal -> IO BS.ByteString
fromJSBytes arr = do
  n <- js_len arr
  BS.pack <$> mapM (\i -> fromIntegral <$> js_idx arr i) [0 .. n - 1]

toJSBytes :: BS.ByteString -> IO JSVal
toJSBytes bs = do
  arr <- js_newBytes (BS.length bs)
  mapM_ (\(i, w) -> js_setByte arr i (fromIntegral w)) (zip [0 ..] (BS.unpack bs))
  pure arr

-- | JS calls this once on socket open; returns the Subscribe frame bytes
-- (one multi-query subscription over the user + message tables) to ws.send.
hs_subscribe :: IO JSVal
hs_subscribe = toJSBytes (runEncoder (\() -> encodeSubscribe 1 1 [userSql, msgSql]) ())
 where
  userSql = "SELECT * FROM " <> tableName app.user
  msgSql = "SELECT * FROM " <> tableName app.message

-- | JS calls this with each received binary frame (a Uint8Array); decodes it,
-- updates the model, and returns the rendered HTML view.
hs_on_frame :: JSVal -> IO JSString
hs_on_frame arr = do
  bs <- fromJSBytes arr
  case decodeFrameNone bs of
    Left _ -> pure ()
    Right msg -> modifyIORef' modelRef (applyMessage msg)
  m <- readIORef modelRef
  pure (toJSString (T.unpack (renderHtml m)))

-- | JS calls this with the message text; returns CallReducer(send_message) bytes.
hs_send_message :: JSString -> IO JSVal
hs_send_message jsText = do
  rid <- nextRid
  toJSBytes (callReducerBytes rid (reducerName app.sendMessage) (SendMessageArgs (T.pack (fromJSString jsText))))

-- | JS calls this with the new name; returns CallReducer(set_name) bytes.
hs_set_name :: JSString -> IO JSVal
hs_set_name jsName = do
  rid <- nextRid
  toJSBytes (callReducerBytes rid (reducerName app.setName) (SetNameArgs (T.pack (fromJSString jsName))))
