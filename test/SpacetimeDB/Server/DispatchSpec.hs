{-# LANGUAGE OverloadedStrings #-}
module SpacetimeDB.Server.DispatchSpec (spec) where

import Data.IORef
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Test.Hspec
import SpacetimeDB.BSATN.Decoder (string, u32)
import SpacetimeDB.BSATN.Encoder (encodeString, runEncoder)
import SpacetimeDB.BSATN.Types (ConnectionId, Timestamp (..), connectionIdFromInteger)
import SpacetimeDB.Server
import SpacetimeDB.Server.Internal (Backend (..), TableId (..))

-- A fake backend that records inserts into an IORef.
fakeBackend :: IORef [(TableId, BS.ByteString)] -> Backend
fakeBackend ref = Backend
  { beTableId = \_ -> pure (Right (TableId 1))
  , beInsert  = \t row -> modifyIORef' ref (++ [(t, row)]) >> pure (Right ())
  , beScan    = \_ -> pure (Right [])
  , beDelete  = \_ _ -> pure (Right ())
  , beLog     = \_ -> pure ()
  }

-- Module with two reducers of different arg types.
testModule :: ModuleDef
testModule = ModuleDef "SCHEMA"
  [ reducer string $ \name -> do
      t <- tableId "person"
      insert t (runEncoder encodeString name)
  , reducer u32 $ \n ->
      if n == 0 then throwError "must be positive"
                else pure ()
  ]

ctx0 :: ReducerContext
ctx0 = mkContext 0 0 0 0 0 0 0

spec :: Spec
spec = describe "dispatch" $ do
  it "dispatches reducer 0 (string) and inserts" $ do
    ref <- newIORef []
    let args = runEncoder encodeString "alice"
    r <- dispatchReducer testModule 0 ctx0 args (fakeBackend ref)
    r `shouldBe` Right ()
    rows <- readIORef ref
    rows `shouldBe` [(TableId 1, args)]

  it "dispatches reducer 1 (u32) and throwError surfaces as Left" $ do
    ref <- newIORef []
    r <- dispatchReducer testModule 1 ctx0 (BS.pack [0,0,0,0]) (fakeBackend ref)
    r `shouldBe` Left "must be positive"

  it "unknown reducer id is Left, not a crash" $ do
    ref <- newIORef []
    r <- dispatchReducer testModule 9 ctx0 BS.empty (fakeBackend ref)
    r `shouldBe` Left "unknown reducer id 9"

  it "arg decode failure is Left" $ do
    ref <- newIORef []
    r <- dispatchReducer testModule 0 ctx0 (BS.pack [1,2]) (fakeBackend ref)  -- truncated string
    case r of Left m -> ("arg decode failed:" `T.isPrefixOf` m) `shouldBe` True; _ -> expectationFailure "expected Left"

  it "mkContext maps a zero connection id to Nothing and non-zero to Just" $ do
    connectionId (mkContext 0 0 0 0 0 0 5) `shouldBe` (Nothing :: Maybe ConnectionId)
    connectionId (mkContext 0 0 0 0 7 0 5) `shouldBe` Just (connectionIdFromInteger 7)
    timestamp (mkContext 0 0 0 0 0 0 42) `shouldBe` Timestamp 42
