{-# LANGUAGE OverloadedStrings #-}

-- | The public client surface: an immutable builder, a durable handle, and the
-- callback-only call operations.
--
-- __Threading contract:__ every callback (@onEvent@, @onError@, typed
-- subscription sinks, and call continuations) runs on one of the client's own
-- threads. Callbacks must be short and must not call a blocking handle
-- operation (e.g. 'start' waiting on the first connect), since that would wait
-- on state the callback's own thread is servicing.
module SpacetimeDB.Client
  ( -- * Config / builder
    Config
  , ReconnectPolicy (..)
  , builder
  , withSecure
  , withBaseUri
  , withToken
  , withCompression
  , withConfirmedReads
  , withReconnect
  , subscribe
  , subscribeQuery
  , onEvent
  , onError

    -- * Handle
  , Client
  , start
  , stop
  , token
  , addSubscription
  , addQuerySubscription
  , unsubscribe

    -- * Calls
  , ReplyPayload (..)
  , TypedRows (..)
  , TypedSink
  , callReducer
  , callProcedure
  , oneOffQuery
  ) where

import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as B
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word32)
import SpacetimeDB.Client.Connection
import SpacetimeDB.Client.Endpoint
import SpacetimeDB.Client.State (LiveSub (..))
import qualified SpacetimeDB.Client.State as St
import SpacetimeDB.Client.Types (ClientError, Event)
import SpacetimeDB.Protocol.Messages (Compression (..), encodeCallProcedure, encodeCallReducer, encodeOneOffQuery, encodeSubscribe, encodeUnsubscribe)

-- | A fresh @NoReconnect@, Brotli-compressed, insecure config for
-- @host@/@port@/@database@.
builder :: Text -> Int -> Text -> Config
builder host port db =
  Config
    { cfgEndpoint = EndpointConfig (HostPort host port False) db CompBrotli Nothing
    , cfgToken = Nothing
    , cfgReconnect = NoReconnect
    , cfgSubs = []
    , cfgOnEvent = const (pure ())
    , cfgOnError = const (pure ())
    }

withSecure :: Bool -> Config -> Config
withSecure sec cfg = cfg {cfgEndpoint = setSecure (cfgEndpoint cfg)}
  where
    setSecure ep = case epBase ep of
      HostPort h p _ -> ep {epBase = HostPort h p sec}
      other -> ep {epBase = other}

withBaseUri :: Text -> Config -> Config
withBaseUri u cfg = cfg {cfgEndpoint = (cfgEndpoint cfg) {epBase = BaseUri u}}

withToken :: Text -> Config -> Config
withToken t cfg = cfg {cfgToken = Just t}

withCompression :: Compression -> Config -> Config
withCompression comp cfg = cfg {cfgEndpoint = (cfgEndpoint cfg) {epCompression = comp}}

withConfirmedReads :: Bool -> Config -> Config
withConfirmedReads b cfg = cfg {cfgEndpoint = (cfgEndpoint cfg) {epConfirmed = Just b}}

withReconnect :: ReconnectPolicy -> Config -> Config
withReconnect p cfg = cfg {cfgReconnect = p}

-- | Declare a raw subscription; rows arrive as 'InitialRows'/'Changed' events.
subscribe :: Text -> Config -> Config
subscribe q cfg = cfg {cfgSubs = cfgSubs cfg ++ [RawSub q Nothing Nothing]}

-- | Declare a typed subscription bound to @table@; rows are delivered to
-- @sink@ instead of the event callback.
subscribeQuery :: Text -> Text -> TypedSink -> Config -> Config
subscribeQuery table q sink cfg = cfg {cfgSubs = cfgSubs cfg ++ [RawSub q (Just table) (Just sink)]}

onEvent :: (Event -> IO ()) -> Config -> Config
onEvent f cfg = cfg {cfgOnEvent = f}

onError :: (ClientError -> IO ()) -> Config -> Config
onError f cfg = cfg {cfgOnError = f}

-- | Connect. With 'NoReconnect' this blocks on the first handshake and returns
-- 'Left' on failure; with a 'Reconnect' policy it returns a handle immediately
-- and retries in the background.
start :: Config -> IO (Either Text Client)
start cfg = do
  let st0 = maybe St.emptyState (St.learnToken St.emptyState) (cfgToken cfg)
      (stN, allocated) = foldl allocOne (st0, []) (cfgSubs cfg)
      allocOne (s, acc) (RawSub q tbl msink) =
        let (s', sub) = St.allocateSub s q tbl
         in (s', acc ++ [(tbl, msink, sub)])
      sinks0 = M.fromList [(t, sink) | (Just t, Just sink, _) <- allocated]
  stVar <- newTVarIO stN
  connVar <- newTVarIO Nothing
  out <- newTQueueIO
  cbs <- newTVarIO M.empty
  sinksVar <- newTVarIO sinks0
  stopVar <- newTVarIO False
  supVar <- newTVarIO Nothing
  let c = Client stVar connVar out cbs sinksVar cfg stopVar supVar
  case cfgReconnect cfg of
    NoReconnect -> do
      first <- newEmptyTMVarIO
      sup <- async (sessionOnce c first)
      atomically (writeTVar supVar (Just sup))
      r <- atomically (takeTMVar first)
      case r of
        Left e -> pure (Left e)
        Right () -> pure (Right c)
    Reconnect {} -> do
      sup <- async (supervisor c)
      atomically (writeTVar supVar (Just sup))
      pure (Right c)

-- | Stop the client: no more reconnects, tear down the current socket.
stop :: Client -> IO ()
stop c = do
  atomically (writeTVar (clStop c) True)
  msup <- readTVarIO (clSup c)
  mapM_ cancel msup

-- | The current session token (server-issued at connect, persists across
-- reconnects), if any.
token :: Client -> IO (Maybe Text)
token c = St.token <$> readTVarIO (clState c)

isConnected :: Client -> STM Bool
isConnected c = isJust <$> readTVar (clConn c)

-- | Add a raw subscription at runtime, returning its id. Sends immediately if
-- connected; otherwise it opens on the next connect.
addSubscription :: Client -> Text -> IO Word32
addSubscription c q = addSub c q Nothing Nothing

-- | Add a typed subscription bound to @table@ at runtime, returning its id.
addQuerySubscription :: Client -> Text -> Text -> TypedSink -> IO Word32
addQuerySubscription c table q sink = addSub c q (Just table) (Just sink)

addSub :: Client -> Text -> Maybe Text -> Maybe TypedSink -> IO Word32
addSub c q tbl msink = do
  (sub, connected) <- atomically $ do
    s <- readTVar (clState c)
    let (s', sub) = St.allocateSub s q tbl
    writeTVar (clState c) s'
    case (tbl, msink) of
      (Just t, Just sink) -> modifyTVar' (clTypedSinks c) (M.insert t sink)
      _ -> pure ()
    conn <- isConnected c
    pure (sub, conn)
  when connected $
    enqueue c (runBuilder (encodeSubscribe (subQuerySetId sub) (subQuerySetId sub) [q]))
  pure (subQuerySetId sub)

-- | Forget a subscription; sends an unsubscribe if connected.
unsubscribe :: Client -> Word32 -> IO ()
unsubscribe c qsid = do
  connected <- atomically $ do
    modifyTVar' (clState c) (`St.forgetSub` qsid)
    isConnected c
  when connected $ enqueue c (runBuilder (encodeUnsubscribe qsid qsid 0))

-- | Call a reducer by canonical @name@ with opaque BSATN @args@; the outcome
-- is delivered to @cont@.
callReducer :: Client -> Text -> ByteString -> CallCont -> IO ()
callReducer c name args = enqueueCall c name (\rid -> encodeCallReducer rid 0 name args)

-- | Call a procedure by canonical @name@ with opaque BSATN @args@.
callProcedure :: Client -> Text -> ByteString -> CallCont -> IO ()
callProcedure c name args = enqueueCall c name (\rid -> encodeCallProcedure rid 0 name args)

-- | Run a one-off SQL @query@.
oneOffQuery :: Client -> Text -> CallCont -> IO ()
oneOffQuery c query = enqueueCall c query (`encodeOneOffQuery` query)

-- | Allocate a request id, store @cont@, and enqueue the frame. If there is no
-- live socket the continuation is run immediately with 'ReplyCallFailed'.
enqueueCall :: Client -> Text -> (Word32 -> B.Builder) -> CallCont -> IO ()
enqueueCall c name mkFrame cont = do
  connected <- readTVarIO (clConn c)
  case connected of
    Nothing -> cont (ReplyCallFailed "not connected")
    Just _ -> do
      rid <- atomically $ do
        s <- readTVar (clState c)
        let (s', r) = St.allocateCall s name
        writeTVar (clState c) s'
        modifyTVar' (clCallCbs c) (M.insert r cont)
        pure r
      enqueue c (runBuilder (mkFrame (fromIntegral rid)))
