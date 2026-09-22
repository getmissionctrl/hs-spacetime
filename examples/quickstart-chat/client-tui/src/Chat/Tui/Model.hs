module Chat.Tui.Model
  ( ChatState (..)
  , InputAction (..)
  , emptyChat
  , upsertUsers
  , removeUsers
  , addMessages
  , displayName
  , renderMessage
  , parseInput
  ) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Text qualified as T

import Chat (Message (..), User (..))
import SpacetimeDB.BSATN.Types (Identity, identityToHex)
import SpacetimeDB.Server.HKD (View (Value))

data InputAction = SendMsg Text | SetNameCmd Text | NoOp
  deriving (Eq, Show)

data ChatState = ChatState
  { csNames :: !(Map Identity Text)
  , csMessages :: ![Message 'Value]
  , csInput :: !Text
  , csStatus :: !Text
  }

emptyChat :: ChatState
emptyChat = ChatState M.empty [] "" "connecting…"

upsertUsers :: [User 'Value] -> ChatState -> ChatState
upsertUsers us s = s {csNames = foldr ins s.csNames us}
 where
  ins (User i mn _) m = case mn of
    Just n | not (T.null n) -> M.insert i n m
    _ -> m

removeUsers :: [User 'Value] -> ChatState -> ChatState
removeUsers us s = s {csNames = foldr (\(User i _ _) -> M.delete i) s.csNames us}

addMessages :: [Message 'Value] -> ChatState -> ChatState
addMessages ms s = s {csMessages = sortOn sentOf (s.csMessages ++ ms)}
 where
  sentOf (Message _ ts _) = ts

displayName :: ChatState -> Identity -> Text
displayName s i = case M.lookup i s.csNames of
  Just n -> n
  Nothing -> "user-" <> T.take 8 (identityToHex i)

renderMessage :: ChatState -> Message 'Value -> Text
renderMessage s (Message sndr _ txt) = displayName s sndr <> ": " <> txt

parseInput :: Text -> InputAction
parseInput raw
  | T.null (T.strip raw) = NoOp
  | Just rest <- T.stripPrefix "/name " raw =
      let name = T.strip rest
       in if T.null name then NoOp else SetNameCmd name
  | otherwise = SendMsg raw
