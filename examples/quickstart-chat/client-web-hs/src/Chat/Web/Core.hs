module Chat.Web.Core
  ( WebModel (..)
  , emptyModel
  , decodeFrameNone
  , applyMessage
  , renderHtml
  , subscribeBytes
  , callReducerBytes
  , modelWithMessage
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)

import Chat (Message (..), User (..))
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.BSATN.Types (Identity, Timestamp (..), identityFromInteger, identityToHex)
import SpacetimeDB.Protocol.Messages
  ( QuerySetUpdate (..)
  , QueryRows (..)
  , ReducerOutcome (..)
  , ServerMessage (..)
  , SingleTableRows (..)
  , TableUpdate (..)
  , TableUpdateRows (..)
  , decodeServerMessage
  , encodeCallReducer
  , encodeSubscribe
  )
import SpacetimeDB.Server.HKD (View (Value))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (decodeVal, encodeVal))

data WebModel = WebModel
  { wmNames :: !(Map Identity Text)
  , wmMessages :: ![Message 'Value]
  , wmSelf :: !(Maybe Identity)
  }

emptyModel :: WebModel
emptyModel = WebModel M.empty [] Nothing

-- | Decode a compression=None server frame: a 0x00 tag then a BSATN ServerMessage.
decodeFrameNone :: ByteString -> Either Text ServerMessage
decodeFrameNone bs = case BS.uncons bs of
  Nothing -> Left "empty frame"
  Just (0, rest) -> either (Left . T.pack . show) Right (runExact decodeServerMessage rest)
  Just (t, _) -> Left ("unexpected compression tag " <> T.pack (show t))

applyMessage :: ServerMessage -> WebModel -> WebModel
applyMessage msg m = case msg of
  InitialConnection ident _conn _tok -> m {wmSelf = Just ident}
  SubscribeApplied _ _ (QueryRows tables) -> foldr applyInitial m tables
  TransactionUpdate qsus -> foldr applyQsu m qsus
  ReducerResult _ _ (OutcomeOk _ qsus) -> foldr applyQsu m qsus
  _ -> m
 where
  applyInitial (SingleTableRows tbl rows) acc = ingest tbl rows [] acc
  applyQsu (QuerySetUpdate _ tus) acc = foldr applyTu acc tus
  applyTu (TableUpdate tbl trs) acc = foldr (applyTr tbl) acc trs
  applyTr tbl (PersistentTable ins del) acc = ingest tbl ins del acc
  applyTr tbl (EventTable evs) acc = ingest tbl evs [] acc

-- | Route a table's inserted/deleted rows into the model.
ingest :: Text -> [ByteString] -> [ByteString] -> WebModel -> WebModel
ingest tbl ins del m
  | tbl == "user" =
      let addNames = [u | Right u <- map (runExact (decodeVal @(User 'Value))) ins]
          delNames = [u | Right u <- map (runExact (decodeVal @(User 'Value))) del]
       in m {wmNames = foldr addU (foldr delU m.wmNames delNames) addNames}
  | tbl == "message" =
      let newMsgs = [x | Right x <- map (runExact (decodeVal @(Message 'Value))) ins]
       in m {wmMessages = sortOn sentOf (m.wmMessages ++ newMsgs)}
  | otherwise = m
 where
  addU (User i mn _) mp = maybe mp (\n -> if T.null n then mp else M.insert i n mp) mn
  delU (User i _ _) mp = M.delete i mp
  sentOf (Message _ ts _) = ts

displayName :: WebModel -> Identity -> Text
displayName m i = case M.lookup i m.wmNames of
  Just n -> n
  Nothing -> "user-" <> T.take 8 (identityToHex i)

renderHtml :: WebModel -> Text
renderHtml m = T.intercalate "\n" [line msg | msg <- m.wmMessages]
 where
  line (Message sndr _ txt) =
    "<div class=\"msg\"><b>" <> esc (displayName m sndr) <> "</b>: " <> esc txt <> "</div>"

-- Composition applies right-to-left, so '&' is escaped first (a real '<'
-- becomes "&lt;", never "&amp;lt;").
esc :: Text -> Text
esc = T.replace "<" "&lt;" . T.replace ">" "&gt;" . T.replace "&" "&amp;"

-- | Outbound Subscribe bytes for a single query at (rid=qsid=n). Raw, no tag.
subscribeBytes :: Word32 -> Text -> ByteString
subscribeBytes n query = runEncoder (\() -> encodeSubscribe n n [query]) ()

-- | Outbound CallReducer bytes. Raw, no tag.
callReducerBytes :: SpacetimeType a => Word32 -> Text -> a -> ByteString
callReducerBytes rid name argv =
  runEncoder (\() -> encodeCallReducer rid 0 name (runEncoder encodeVal argv)) ()

-- Test helper: a model holding one message with the given text.
modelWithMessage :: Text -> WebModel
modelWithMessage t =
  emptyModel {wmMessages = [Message (identityFromInteger 0) (Timestamp 0) t]}
