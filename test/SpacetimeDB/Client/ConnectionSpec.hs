module SpacetimeDB.Client.ConnectionSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Function ((&))
import Data.IORef
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.Client
import SpacetimeDB.Client.Types

spec :: Spec
spec = do
  it "NoReconnect: start returns HandshakeFailed against a closed port" $ do
    r <-
      start
        ( builder (T.pack "127.0.0.1") 59999 (T.pack "nodb")
            & withReconnect NoReconnect
        )
    case r of
      Left _ -> pure ()
      Right _ -> expectationFailure "expected handshake failure"
  it "Reconnect: start succeeds and emits Reconnecting(1)" $ do
    seen <- newIORef []
    r <-
      start
        ( builder (T.pack "127.0.0.1") 59999 (T.pack "nodb")
            & withReconnect (Reconnect 50 200 (Just 1))
            & onEvent (\e -> modifyIORef seen (e :))
        )
    case r of
      Left _ -> expectationFailure "expected a handle"
      Right c -> do threadDelay 300000; stop c
    evs <- readIORef seen
    any isReconnecting evs `shouldBe` True
  where
    isReconnecting (Reconnecting 1 _) = True
    isReconnecting _ = False
