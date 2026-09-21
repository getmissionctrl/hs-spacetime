module Chat.Tui.ModelSpec (spec) where

import qualified Data.Map.Strict as M
import Test.Hspec

import Chat (Message (..), User (..))
import Chat.Tui.Model
import SpacetimeDB.BSATN.Types (Identity, Timestamp (..), identityFromInteger)
import SpacetimeDB.Server.HKD (View (Value))

i1, i2 :: Identity
i1 = identityFromInteger 1
i2 = identityFromInteger 2

spec :: Spec
spec = do
  describe "parseInput" $ do
    it "treats plain text as a message" $
      parseInput "hello" `shouldBe` SendMsg "hello"
    it "treats /name X as a set-name command" $
      parseInput "/name alice" `shouldBe` SetNameCmd "alice"
    it "ignores blank input" $
      parseInput "   " `shouldBe` NoOp
    it "ignores /name with no argument" $
      parseInput "/name   " `shouldBe` NoOp

  describe "name map" $ do
    it "records names from users with a name" $ do
      let s = upsertUsers [User i1 (Just "alice") True] emptyChat
      displayName s i1 `shouldBe` "alice"
    it "falls back to an id prefix when unknown" $
      displayName emptyChat i1 `shouldNotBe` ""
    it "drops names on user removal" $ do
      let s = removeUsers [User i1 (Just "alice") False]
                (upsertUsers [User i1 (Just "alice") True] emptyChat)
      displayName s i1 `shouldNotBe` "alice"

  describe "renderMessage" $
    it "renders as 'name: text' using the name map" $ do
      let s = upsertUsers [User i2 (Just "bob") True] emptyChat
      renderMessage s (Message i2 (Timestamp 0) "hi") `shouldBe` "bob: hi"
