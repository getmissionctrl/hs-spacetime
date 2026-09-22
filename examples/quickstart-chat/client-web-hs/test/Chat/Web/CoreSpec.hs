module Chat.Web.CoreSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Test.Hspec

import Chat (App (..), app)
import Chat.Web.Core
import SpacetimeDB.Protocol.Messages (encodeSubscribe)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Server.Table (tableName)

spec :: Spec
spec = do
  describe "decodeFrameNone" $ do
    it "rejects a frame whose compression tag is not 0" $
      decodeFrameNone (BS.pack [1, 2, 3]) `shouldSatisfy` isLeft
    it "rejects an empty frame" $
      decodeFrameNone BS.empty `shouldSatisfy` isLeft

  describe "subscribeBytes" $
    it "matches the native encodeSubscribe wire bytes" $ do
      let userSql = "SELECT * FROM " <> tableName app.user
          native = runEncoder (\() -> encodeSubscribe 1 1 [userSql]) ()
      subscribeBytes 1 userSql `shouldBe` native

  describe "renderHtml" $
    it "escapes angle brackets in message text" $
      T.isInfixOf "&lt;script&gt;" (renderHtml (modelWithMessage "<script>")) `shouldBe` True
 where
  isLeft = either (const True) (const False)
