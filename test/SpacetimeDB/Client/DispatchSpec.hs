module SpacetimeDB.Client.DispatchSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import SpacetimeDB.Client.Dispatch
import SpacetimeDB.Client.State (LiveSub (..))
import SpacetimeDB.Protocol.Messages
import Test.Hspec

spec :: Spec
spec = do
  let widgetSub = LiveSub 1 (T.pack "SELECT * FROM widget") (Just (T.pack "widget"))
      row = BS.pack [1]
  describe "routeTableUpdate" $ do
    it "sends to typed dispatcher when a sub owns the table" $
      routeTableUpdate [widgetSub] (TableUpdate (T.pack "widget") [PersistentTable [row] []])
        `shouldBe` [ToTyped (T.pack "widget") (T.pack "SELECT * FROM widget") [row] []]
    it "sends to raw path when no typed sub owns the table" $
      routeTableUpdate [] (TableUpdate (T.pack "other") [PersistentTable [row] []])
        `shouldBe` [ToRaw (Changed' (T.pack "other") [row] [])]
    it "suppresses empty persistent ops" $
      routeTableUpdate [] (TableUpdate (T.pack "other") [PersistentTable [] []]) `shouldBe` []
    it "event tables map to inserts-only Changed" $
      routeTableUpdate [widgetSub] (TableUpdate (T.pack "widget") [EventTable [row]])
        `shouldBe` [ToTyped (T.pack "widget") (T.pack "SELECT * FROM widget") [row] []]
