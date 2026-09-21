module ChatSpec (spec) where

import Chat (App (..), Message (..), SendMessageArgs (..), SetNameArgs (..), User (..), app, chatModule)
import Data.ByteString (ByteString)
import FakeBackend (backendFor, newFake, rowsOf)
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.BSATN.Types (Timestamp (..), identityFromInteger)
import SpacetimeDB.Server (dispatchReducer, lifecycleHookName, mkContext, reducerName, tableName)
import SpacetimeDB.Server.HKD (View (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import Test.Hspec

spec :: Spec
spec = describe "Chat.app" $ do
  it "derives snake_case table/reducer/lifecycle handle names" $ do
    tableName app.user `shouldBe` "user"
    tableName app.message `shouldBe` "message"
    reducerName app.setName `shouldBe` "set_name"
    reducerName app.sendMessage `shouldBe` "send_message"
    lifecycleHookName app.init `shouldBe` "init"
    lifecycleHookName app.clientConnected `shouldBe` "client_connected"
    lifecycleHookName app.clientDisconnected `shouldBe` "client_disconnected"

  it "send_message inserts one Message stamped with sender + timestamp" $ do
    ref <- newFake
    r <-
      dispatchReducer
        chatModule
        1
        (mkContext 0 0 0 0 0 0 7)
        (runEncoder encodeVal (SendMessageArgs "hi"))
        (backendFor ref)
    r `shouldBe` Right ()
    rows <- rowsOf ref "message"
    map (runExact (decodeVal @(Message 'Value))) rows
      `shouldBe` [Right (Message (identityFromInteger 0) (Timestamp 7) "hi")]

  it "send_message rejects empty text" $ do
    ref <- newFake
    r <-
      dispatchReducer
        chatModule
        1
        (mkContext 0 0 0 0 0 0 0)
        (runEncoder encodeVal (SendMessageArgs ""))
        (backendFor ref)
    r `shouldBe` Left "Messages must not be empty"

  it "client_connected inserts a new online user" $ do
    ref <- newFake
    _ <- dispatchReducer chatModule 3 (mkContext 0 0 0 0 0 0 0) (mempty :: ByteString) (backendFor ref)
    rows <- rowsOf ref "user"
    map (runExact (decodeVal @(User 'Value))) rows
      `shouldBe` [Right (User (identityFromInteger 0) Nothing True)]

  it "set_name errors for an unknown user" $ do
    ref <- newFake
    r <-
      dispatchReducer
        chatModule
        0
        (mkContext 0 0 0 0 0 0 0)
        (runEncoder encodeVal (SetNameArgs "alice"))
        (backendFor ref)
    r `shouldBe` Left "Cannot set name for unknown user"

  it "set_name rejects an empty name" $ do
    ref <- newFake
    r <-
      dispatchReducer
        chatModule
        0
        (mkContext 0 0 0 0 0 0 0)
        (runEncoder encodeVal (SetNameArgs ""))
        (backendFor ref)
    r `shouldBe` Left "Names must not be empty"

  it "set_name updates an existing user's name" $ do
    ref <- newFake
    let be = backendFor ref
    _ <- dispatchReducer chatModule 3 (mkContext 0 0 0 0 0 0 0) (mempty :: ByteString) be
    r <-
      dispatchReducer
        chatModule
        0
        (mkContext 0 0 0 0 0 0 0)
        (runEncoder encodeVal (SetNameArgs "alice"))
        be
    r `shouldBe` Right ()
    rows <- rowsOf ref "user"
    map (runExact (decodeVal @(User 'Value))) rows
      `shouldBe` [Right (User (identityFromInteger 0) (Just "alice") True)]

  it "client_disconnected marks the user offline" $ do
    ref <- newFake
    let be = backendFor ref
    _ <- dispatchReducer chatModule 3 (mkContext 0 0 0 0 0 0 0) (mempty :: ByteString) be
    _ <- dispatchReducer chatModule 4 (mkContext 0 0 0 0 0 0 0) (mempty :: ByteString) be
    rows <- rowsOf ref "user"
    map (runExact (decodeVal @(User 'Value))) rows
      `shouldBe` [Right (User (identityFromInteger 0) Nothing False)]

  it "client_connected re-marks a returning user online, keeping name" $ do
    ref <- newFake
    let be = backendFor ref
    _ <- dispatchReducer chatModule 3 (mkContext 0 0 0 0 0 0 0) (mempty :: ByteString) be
    _ <- dispatchReducer chatModule 0 (mkContext 0 0 0 0 0 0 0) (runEncoder encodeVal (SetNameArgs "bob")) be
    _ <- dispatchReducer chatModule 4 (mkContext 0 0 0 0 0 0 0) (mempty :: ByteString) be
    _ <- dispatchReducer chatModule 3 (mkContext 0 0 0 0 0 0 0) (mempty :: ByteString) be
    rows <- rowsOf ref "user"
    map (runExact (decodeVal @(User 'Value))) rows
      `shouldBe` [Right (User (identityFromInteger 0) (Just "bob") True)]
