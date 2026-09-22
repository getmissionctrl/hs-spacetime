module Chat.Web.CoreSpec (spec) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Test.Hspec

import Chat (App (..), app)
import Chat.Web.Core
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Protocol.Messages (encodeSubscribe)
import SpacetimeDB.Server.Table (tableName)

spec :: Spec
spec = do
  describe "decodeFrameNone" $ do
    it "rejects a frame whose compression tag is not 0" $
      decodeFrameNone (BS.pack [1, 2, 3]) `shouldSatisfy` isLeft
    it "rejects an empty frame" $
      decodeFrameNone BS.empty `shouldSatisfy` isLeft

  describe "subscribeBytes" $ do
    it "matches native encodeSubscribe for a single query" $ do
      let userSql = "SELECT * FROM " <> tableName app.user
          native = runEncoder (\() -> encodeSubscribe 1 1 [userSql]) ()
      subscribeBytes 1 [userSql] `shouldBe` native
    it "matches native encodeSubscribe for the two-query frame the client sends" $ do
      let userSql = "SELECT * FROM " <> tableName app.user
          msgSql = "SELECT * FROM " <> tableName app.message
          native = runEncoder (\() -> encodeSubscribe 1 1 [userSql, msgSql]) ()
      subscribeBytes 1 [userSql, msgSql] `shouldBe` native

  describe "renderHtml" $ do
    it "escapes angle brackets in message text" $
      T.isInfixOf "&lt;script&gt;" (renderHtml (modelWithMessage "<script>")) `shouldBe` True
    it "escapes ampersands (before angle brackets, no double-encoding)" $
      T.isInfixOf "a&amp;b" (renderHtml (modelWithMessage "a&b")) `shouldBe` True
 where
  isLeft = either (const True) (const False)
