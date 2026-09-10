{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Client.Types
  ( Event (..)
  , ClientError (..)
  , RowBatch (..)
  , ReducerReply (..)
  , ProcedureReply (..)
  , QueryReply (..)
  , formatEvent
  , formatError
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8, Word32)
import SpacetimeDB.BSATN.Decoder (DecodeError)
import SpacetimeDB.BSATN.Types (ConnectionId, Identity)

data RowBatch = BatchInitial | BatchInsert | BatchDelete deriving (Eq, Show)

data Event
  = Connected Identity ConnectionId Text
  | Disconnected Text
  | Reconnecting Int Int
  | InitialRows Text [ByteString]
  | Changed Text [ByteString] [ByteString]
  | SubscriptionFailed Word32 Text
  | Unsubscribed Word32
  | UnhandledMessage Word8
  | UnmatchedReply Word32
  deriving (Eq, Show)

data ClientError
  = HandshakeFailed Text
  | DecodeFailed Text
  | SendFailed Text
  | RowDecodeFailed Text RowBatch Int DecodeError
  | CallFailed Text Text
  deriving (Eq, Show)

data ReducerReply a e = Returned a | ReturnedNothing | Failed e | ReducerCallFailed Text
  deriving (Eq, Show)
data ProcedureReply a = ProcReturnedVal a | ProcedureCallFailed Text deriving (Eq, Show)
data QueryReply = QueryReturned [(Text, [ByteString])] | QueryRejected Text | QueryCallFailed Text
  deriving (Eq, Show)

formatEvent :: Event -> Text
formatEvent e = case e of
  Connected _ _ _ -> "connected"
  Disconnected r -> "disconnected: " <> r
  Reconnecting a d -> "reconnecting attempt " <> T.pack (show a) <> " in " <> T.pack (show d) <> "ms"
  InitialRows t rs -> "initial " <> t <> " (" <> T.pack (show (length rs)) <> " rows)"
  Changed t ins del ->
    "changed " <> t <> " (+" <> T.pack (show (length ins))
      <> " -" <> T.pack (show (length del)) <> ")"
  SubscriptionFailed q m -> "subscription " <> T.pack (show q) <> " failed: " <> m
  Unsubscribed q -> "unsubscribed " <> T.pack (show q)
  UnhandledMessage tag -> "unhandled message tag " <> T.pack (show tag)
  UnmatchedReply rid -> "unmatched reply " <> T.pack (show rid)

formatError :: ClientError -> Text
formatError err = case err of
  HandshakeFailed r -> "handshake failed: " <> r
  DecodeFailed r -> "decode failed: " <> r
  SendFailed r -> "send failed: " <> r
  RowDecodeFailed q _ i _ -> "row decode failed for " <> q <> " at index " <> T.pack (show i)
  CallFailed n r -> "call " <> n <> " failed: " <> r
