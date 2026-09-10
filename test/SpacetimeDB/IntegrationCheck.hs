{-# LANGUAGE OverloadedStrings #-}

{- | Opt-in end-to-end checks against a real SpacetimeDB server booted by the
harness. Gated behind @SPACETIMEDB_INTEGRATION=1@ so the default suite stays
hermetic.
-}
module SpacetimeDB.IntegrationCheck (spec) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad (unless)
import Data.Function ((&))
import qualified Data.Text as T
import SpacetimeDB.BSATN.Encoder (encodeString, encodeU32)
import SpacetimeDB.Client
import SpacetimeDB.Client.Types (Event (..))
import SpacetimeDB.Live.Harness (waitUntil, withLiveServer)
import Test.Hspec

spec :: Spec
spec = describe "live end-to-end" $
  it "connects, sees seeded rows, calls add_widget, observes the insert" $
    withLiveServer $ \port db -> do
      events <- newTVarIO []
      let record e = atomically (modifyTVar' events (e :))
      started <-
        start
          ( builder (T.pack "127.0.0.1") port db
              & withReconnect (Reconnect 200 2000 Nothing)
              & subscribe (T.pack "SELECT * FROM widget")
              & onEvent record
          )
      client <- case started of
        Left e -> fail ("start failed: " ++ T.unpack e)
        Right c -> pure c

      -- 1. handshake
      connected <- waitUntil events (any isConnected) 5000
      unless connected $ expectationFailure "no Connected event"

      -- 2. initial rows from the seeded `init` reducer
      seeded <- waitUntil events (any (isInitialWidget)) 5000
      unless seeded $ expectationFailure "no initial widget rows"

      -- 3. call add_widget and get a reply
      reply <- newEmptyMVar
      callReducer
        client
        (T.pack "add_widget")
        (buildArgs [encodeString (T.pack "gizmo"), encodeU32 5])
        (putMVar reply)
      r <- takeMVar reply
      case r of
        ReplyReducer _ -> pure ()
        ReplyCallFailed why -> expectationFailure ("reducer call failed: " ++ T.unpack why)
        _ -> expectationFailure "unexpected reply kind"

      -- 4. observe the resulting insert
      changed <- waitUntil events (any isChangedWidget) 5000
      unless changed $ expectationFailure "no Changed widget event after add_widget"

      stop client
 where
  isConnected Connected {} = True
  isConnected _ = False
  isInitialWidget (InitialRows t rows) = t == T.pack "widget" && not (null rows)
  isInitialWidget _ = False
  isChangedWidget (Changed t ins _) = t == T.pack "widget" && not (null ins)
  isChangedWidget _ = False
