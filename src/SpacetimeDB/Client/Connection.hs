{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The one IO module: a durable 'TVar' 'ClientState' plus a per-connection
socket, a serialised outbound queue, an exception-bounded reconnect
supervisor, and the server-message handler that drives dispatch and reply
delivery. All the decision logic lives in the pure modules
("SpacetimeDB.Client.State" / "SpacetimeDB.Client.Dispatch"); this module
only wires them to a websocket.
-}
module SpacetimeDB.Client.Connection
  ( Config (..)
  , ReconnectPolicy (..)
  , RawSub (..)
  , TypedSink
  , TypedRows (..)
  , ReplyPayload (..)
  , CallCont
  , Client (..)
  , runBuilder
  , enqueue
  , fireEvent
  , fireError
  , runSession
  , sessionOnce
  , supervisor
  , handleDisconnect
  , replaySubs
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, race_)
import Control.Concurrent.STM
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forever, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BL
import qualified Data.CaseInsensitive as CI
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import qualified Network.WebSockets as WS
import SpacetimeDB.Client.Dispatch
import SpacetimeDB.Client.Endpoint
import SpacetimeDB.Client.State (ClientState, LiveSub (..))
import qualified SpacetimeDB.Client.State as St
import SpacetimeDB.Client.Types
import SpacetimeDB.Protocol.Frame (decodeFrame)
import SpacetimeDB.Protocol.Messages
import qualified Wuss

{- | Reconnect behaviour. Backoff milliseconds are doubled after each failed
attempt, capped at 'maxMs'; 'maxAttempts' 'Nothing' means never give up.
-}
data ReconnectPolicy
  = NoReconnect
  | Reconnect {initialMs :: Int, maxMs :: Int, maxAttempts :: Maybe Int}
  deriving (Eq, Show)

-- | A typed subscription sink receives already-split rows for one table.
data TypedRows = TypedInitial [ByteString] | TypedChange [ByteString] [ByteString]
  deriving (Eq, Show)

type TypedSink = TypedRows -> IO ()

{- | A builder-declared subscription. A 'Just' table makes it a typed
subscription routed to 'rsSink'; 'Nothing' makes it a raw subscription
surfaced through 'cfgOnEvent'.
-}
data RawSub = RawSub
  { rsQuery :: Text
  , rsTable :: Maybe Text
  , rsSink :: Maybe TypedSink
  }

{- | Immutable connection configuration assembled by the builder in
"SpacetimeDB.Client".
-}
data Config = Config
  { cfgEndpoint :: EndpointConfig
  , cfgToken :: Maybe Text
  , cfgReconnect :: ReconnectPolicy
  , cfgSubs :: [RawSub]
  , cfgOnEvent :: Event -> IO ()
  , cfgOnError :: ClientError -> IO ()
  }

-- | The raw payload handed to a stored call continuation.
data ReplyPayload
  = ReplyReducer ReducerOutcome
  | ReplyProcedure ProcedureStatus
  | ReplyOneOff (Either Text QueryRows)
  | ReplyCallFailed Text

type CallCont = ReplyPayload -> IO ()

{- | The durable client handle. Everything that must outlive a single socket
lives here; the socket itself is 'clConn' and is disposable.
-}
data Client = Client
  { clState :: TVar ClientState
  , clConn :: TVar (Maybe WS.Connection)
  , clOutbound :: TQueue ByteString
  , clCallCbs :: TVar (Map Int CallCont)
  , clTypedSinks :: TVar (Map Text TypedSink)
  , clConfig :: Config
  , clStop :: TVar Bool
  , clSup :: TVar (Maybe (Async ()))
  }

runBuilder :: B.Builder -> ByteString
runBuilder = BL.toStrict . B.toLazyByteString

enqueue :: Client -> ByteString -> IO ()
enqueue c bs = atomically (writeTQueue (clOutbound c) bs)

fireEvent :: Client -> Event -> IO ()
fireEvent c = cfgOnEvent (clConfig c)

fireError :: Client -> ClientError -> IO ()
fireError c = cfgOnError (clConfig c)

-- | Resolve the endpoint into the four values the websocket client needs.
targetOf :: EndpointConfig -> Either Text (Bool, String, Int, String)
targetOf ep = case epBase ep of
  HostPort h p secure -> Right (secure, T.unpack h, p, tailPath)
  BaseUri u -> parseBase u
 where
  tailPath =
    "/v1/database/"
      ++ T.unpack (epDatabase ep)
      ++ "/subscribe?compression="
      ++ comp
      ++ confirmed
  comp = case epCompression ep of
    CompNone -> "None"
    CompBrotli -> "Brotli"
    CompGzip -> "Gzip"
  confirmed = case epConfirmed ep of
    Nothing -> ""
    Just True -> "&confirmed=true"
    Just False -> "&confirmed=false"
  parseBase u0 =
    let u1 = rewrite (T.dropWhileEnd (== '/') u0)
        (secure, afterScheme)
          | T.isPrefixOf "https://" u1 = (True, T.drop 8 u1)
          | T.isPrefixOf "http://" u1 = (False, T.drop 7 u1)
          | otherwise = (False, u1)
        (authority, prefix) = T.break (== '/') afterScheme
        (hostT, portT) = T.break (== ':') authority
        port
          | T.null portT = if secure then 443 else 80
          | otherwise = read (T.unpack (T.drop 1 portT))
     in if T.null hostT
          then Left "empty host in base URI"
          else Right (secure, T.unpack hostT, port, T.unpack prefix ++ tailPath)
  rewrite v
    | T.isPrefixOf "wss://" v = "https://" <> T.drop 6 v
    | T.isPrefixOf "ws://" v = "http://" <> T.drop 5 v
    | otherwise = v

headers :: Client -> WS.Headers
headers c =
  (CI.mk "Sec-WebSocket-Protocol", "v2.bsatn.spacetimedb")
    : case cfgToken (clConfig c) of
      Just t -> [(CI.mk "Authorization", BS8.pack ("Bearer " ++ T.unpack t))]
      Nothing -> []

{- | Open one websocket, run @onOpen@, then race the reader and writer until
one dies. Throws on connect failure (caught by the caller).
-}
runSession :: Client -> IO () -> IO ()
runSession c onOpen =
  case targetOf (cfgEndpoint (clConfig c)) of
    Left e -> throwIO (userError (T.unpack e))
    Right (secure, host, port, path) ->
      let app conn = do
            atomically (writeTVar (clConn c) (Just conn))
            onOpen
            replaySubs c
            race_ (readerLoop c conn) (writerLoop c conn)
       in if secure
            then Wuss.runSecureClientWith host (fromIntegral port) path WS.defaultConnectionOptions (headers c) app
            else WS.runClientWith host port path WS.defaultConnectionOptions (headers c) app

-- | Re-issue every live subscription under its existing id.
replaySubs :: Client -> IO ()
replaySubs c = do
  subs <- St.subscriptions <$> readTVarIO (clState c)
  mapM_
    ( \sub ->
        enqueue c (runBuilder (encodeSubscribe (subQuerySetId sub) (subQuerySetId sub) [subQuery sub]))
    )
    subs

writerLoop :: Client -> WS.Connection -> IO ()
writerLoop c conn = forever $ do
  bs <- atomically (readTQueue (clOutbound c))
  WS.sendBinaryData conn bs

readerLoop :: Client -> WS.Connection -> IO ()
readerLoop c conn = forever $ do
  bs <- WS.receiveData conn
  case decodeFrame bs of
    Left e -> fireError c (DecodeFailed (T.pack (show e)))
    Right msg -> handle c msg

{- | A single connection attempt used for 'NoReconnect' and to signal the first
handshake result via @first@.
-}
sessionOnce :: Client -> TMVar (Either Text ()) -> IO ()
sessionOnce c first = do
  r <- try (runSession c (void (atomically (tryPutTMVar first (Right ()))))) :: IO (Either SomeException ())
  _ <- atomically (tryPutTMVar first (Left (reasonOf r)))
  handleDisconnect c (reasonOf r)
  atomically (writeTVar (clStop c) True)

-- | The reconnect loop for 'Reconnect' policies.
supervisor :: Client -> IO ()
supervisor c = go (initial pol) (1 :: Int)
 where
  pol = cfgReconnect (clConfig c)
  initial (Reconnect ms _ _) = ms
  initial NoReconnect = 0
  go backoff attempt = do
    stop <- readTVarIO (clStop c)
    if stop
      then pure ()
      else do
        r <- try (runSession c (pure ())) :: IO (Either SomeException ())
        handleDisconnect c (reasonOf r)
        stop' <- readTVarIO (clStop c)
        if stop'
          then pure ()
          else case pol of
            NoReconnect -> pure ()
            Reconnect _ mx mattempts -> case mattempts of
              Just m | attempt > m -> pure ()
              _ -> do
                fireEvent c (Reconnecting attempt backoff)
                threadDelay (backoff * 1000)
                go (min mx (backoff * 2)) (attempt + 1)

reasonOf :: Either SomeException () -> Text
reasonOf = either (T.pack . show) (const "connection closed")

{- | Tear-down shared by every session end: clear the socket, fail every
in-flight call so no caller hangs, and fire 'Disconnected'.
-}
handleDisconnect :: Client -> Text -> IO ()
handleDisconnect c reason = do
  drained <- atomically $ do
    writeTVar (clConn c) Nothing
    modifyTVar' (clState c) (fst . St.drainPending)
    cbs <- readTVar (clCallCbs c)
    writeTVar (clCallCbs c) M.empty
    pure (M.elems cbs)
  mapM_ (\cont -> cont (ReplyCallFailed reason)) drained
  fireEvent c (Disconnected reason)

{- | Apply one server message: token/greeting, subscription lifecycle, row
dispatch, and reply delivery. Ordering follows the spec — a reducer's Ok
rows are dispatched before its reply is delivered; one-off/procedure rows
(there are none) bypass table routing.
-}
handle :: Client -> ServerMessage -> IO ()
handle c msg = case msg of
  InitialConnection ident conn tok -> do
    atomically (modifyTVar' (clState c) (`St.learnToken` tok))
    fireEvent c (Connected ident conn tok)
  SubscribeApplied _rid _qsid (QueryRows tables) -> do
    subs <- St.subscriptions <$> readTVarIO (clState c)
    mapM_ (\str -> mapM_ (runInitialAction c) (routeInitial subs str)) tables
  UnsubscribeApplied _rid qsid _ -> do
    atomically (modifyTVar' (clState c) (`St.forgetSub` qsid))
    fireEvent c (Unsubscribed qsid)
  SubscriptionError _mrid qsid emsg -> do
    atomically (modifyTVar' (clState c) (`St.forgetSub` qsid))
    fireEvent c (SubscriptionFailed qsid emsg)
  TransactionUpdate qsus -> dispatchUpdates c qsus
  OneOffQueryResult rid res -> deliver c rid (ReplyOneOff res)
  ReducerResult rid _ts outcome -> do
    case outcome of
      OutcomeOk _ embedded -> dispatchUpdates c embedded
      _ -> pure ()
    deliver c rid (ReplyReducer outcome)
  ProcedureResult status _ts _dur rid -> deliver c rid (ReplyProcedure status)
  Unhandled tag -> fireEvent c (UnhandledMessage tag)

dispatchUpdates :: Client -> [QuerySetUpdate] -> IO ()
dispatchUpdates c qsus = do
  subs <- St.subscriptions <$> readTVarIO (clState c)
  mapM_
    ( \(QuerySetUpdate _qsid tus) ->
        mapM_ (\tu -> mapM_ (runChangeAction c) (routeTableUpdate subs tu)) tus
    )
    qsus

runInitialAction :: Client -> DispatchAction -> IO ()
runInitialAction c a = case a of
  ToTyped t _ rows _ -> typedOrRaw c t (TypedInitial rows) (InitialRows t rows)
  ToRaw (Initial' t rows) -> fireEvent c (InitialRows t rows)
  ToRaw (Changed' t ins del) -> fireEvent c (Changed t ins del)

runChangeAction :: Client -> DispatchAction -> IO ()
runChangeAction c a = case a of
  ToTyped t _ ins del -> typedOrRaw c t (TypedChange ins del) (Changed t ins del)
  ToRaw (Changed' t ins del) -> fireEvent c (Changed t ins del)
  ToRaw (Initial' t rows) -> fireEvent c (InitialRows t rows)

typedOrRaw :: Client -> Text -> TypedRows -> Event -> IO ()
typedOrRaw c t typed rawEvent = do
  sinks <- readTVarIO (clTypedSinks c)
  maybe (fireEvent c rawEvent) ($ typed) (M.lookup t sinks)

{- | Route a reply for @ridW@ to its stored continuation, forgetting it; an
unknown id becomes an 'UnmatchedReply' event.
-}
deliver :: Client -> Word32 -> ReplyPayload -> IO ()
deliver c ridW payload = do
  let rid = fromIntegral ridW :: Int
  mcont <- atomically $ do
    modifyTVar' (clState c) (\s -> fst (St.takePending s rid))
    cbs <- readTVar (clCallCbs c)
    writeTVar (clCallCbs c) (M.delete rid cbs)
    pure (M.lookup rid cbs)
  maybe (fireEvent c (UnmatchedReply ridW)) ($ payload) mcont
