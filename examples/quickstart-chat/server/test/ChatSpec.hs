module ChatSpec (spec) where

import Chat (App (..), Message (..), SendMessageArgs (..), app, chatModule)
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
