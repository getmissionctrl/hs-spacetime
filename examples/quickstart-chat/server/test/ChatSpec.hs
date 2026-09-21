module ChatSpec (spec) where

import Chat (App (..), app)
import SpacetimeDB.Server (lifecycleHookName, reducerName, tableName)
import Test.Hspec

spec :: Spec
spec = describe "Chat.app" $
  it "derives snake_case table/reducer/lifecycle handle names" $ do
    tableName app.user `shouldBe` "user"
    tableName app.message `shouldBe` "message"
    reducerName app.setName `shouldBe` "set_name"
    reducerName app.sendMessage `shouldBe` "send_message"
    lifecycleHookName app.init `shouldBe` "init"
    lifecycleHookName app.clientConnected `shouldBe` "client_connected"
    lifecycleHookName app.clientDisconnected `shouldBe` "client_disconnected"
