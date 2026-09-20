{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module SpacetimeDB.Server.TableSpec (spec) where

import qualified Data.ByteString as BS
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Server (ReducerM, mkContext)
import SpacetimeDB.Server.Internal (Backend (..), TableId (..), runReducerM)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Table
import Test.Hspec

data Event = Event {who :: Text, at :: Int64}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (SpacetimeType)

eventTable :: Table Event
eventTable = table "event"

-- A fake backend: records inserts into an IORef and serves canned scan bytes.
mkBackend :: IORef [BS.ByteString] -> BS.ByteString -> Backend
mkBackend ins scanBytes =
  Backend
    { tableId = \_ -> pure (Right (TableId 1))
    , insert = \_ row -> modifyIORef' ins (++ [row]) >> pure (Right ())
    , scan = \_ -> pure (Right scanBytes)
    , delete = \_ _ -> pure (Right ())
    , log = \_ -> pure ()
    }

run :: Backend -> ReducerM a -> IO (Either Text a)
run be act = runReducerM act (mkContext 0 0 0 0 0 0 0) be

spec :: Spec
spec = describe "Server.Table" $ do
  it "insertRow encodes the row via its SpacetimeType" $ do
    ins <- newIORef []
    r <- run (mkBackend ins BS.empty) (insertRow eventTable (Event "alice" 42))
    r `shouldBe` Right ()
    rows <- readIORef ins
    rows `shouldBe` [runEncoder encodeVal (Event "alice" 42)]

  it "scanRows decodes each row from the batch" $ do
    ins <- newIORef []
    let e1 = Event "a" 1
        e2 = Event "b" 2
        batch = runEncoder encodeVal e1 <> runEncoder encodeVal e2
    r <- run (mkBackend ins batch) (scanRows eventTable)
    r `shouldBe` Right [e1, e2]
