module SpacetimeDB.Protocol.Messages
  ( Compression (..)
  , ServerMessage (..)
  , QueryRows (..), SingleTableRows (..)
  , QuerySetUpdate (..), TableUpdate (..), TableUpdateRows (..)
  , ReducerOutcome (..), ProcedureStatus (..)
  , decodeServerMessage
  , decodeReducerOutcome
  , ClientMessage (..)
  , encodeClientMessage
  , encodeSubscribe, encodeUnsubscribe, encodeOneOffQuery
  , encodeCallReducer, encodeCallProcedure
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as B
import Data.Text (Text)
import Data.Word (Word8, Word32)
import SpacetimeDB.BSATN.Decoder
import SpacetimeDB.BSATN.Encoder
import SpacetimeDB.BSATN.Types
import SpacetimeDB.Protocol.RowList

data Compression = CompNone | CompBrotli | CompGzip deriving (Eq, Show)

data QueryRows = QueryRows [SingleTableRows] deriving (Eq, Show)
data SingleTableRows = SingleTableRows Text [ByteString] deriving (Eq, Show)
data QuerySetUpdate = QuerySetUpdate Word32 [TableUpdate] deriving (Eq, Show)
data TableUpdate = TableUpdate Text [TableUpdateRows] deriving (Eq, Show)
data TableUpdateRows = PersistentTable [ByteString] [ByteString] | EventTable [ByteString]
  deriving (Eq, Show)
data ReducerOutcome
  = OutcomeOk ByteString [QuerySetUpdate]
  | OutcomeOkEmpty
  | OutcomeErr ByteString
  | OutcomeInternalError Text
  deriving (Eq, Show)
data ProcedureStatus = ProcReturned ByteString | ProcInternalError Text deriving (Eq, Show)

data ServerMessage
  = InitialConnection Identity ConnectionId Text
  | SubscribeApplied Word32 Word32 QueryRows
  | UnsubscribeApplied Word32 Word32 (Maybe QueryRows)
  | SubscriptionError (Maybe Word32) Word32 Text
  | TransactionUpdate [QuerySetUpdate]
  | OneOffQueryResult Word32 (Either Text QueryRows)
  | ReducerResult Word32 Timestamp ReducerOutcome
  | ProcedureResult ProcedureStatus Timestamp TimeDuration Word32
  | Unhandled Word8
  deriving (Eq, Show)

decodeSingleTableRows :: Decoder SingleTableRows
decodeSingleTableRows = SingleTableRows <$> string <*> decodeRowList

decodeQueryRows :: Decoder QueryRows
decodeQueryRows = QueryRows <$> list decodeSingleTableRows

decodeTableUpdateRows :: Decoder TableUpdateRows
decodeTableUpdateRows = sumD $ \t -> case t of
  0 -> Right (PersistentTable <$> decodeRowList <*> decodeRowList)
  1 -> Right (EventTable <$> decodeRowList)
  _ -> Left (UnknownVariant t)

decodeTableUpdate :: Decoder TableUpdate
decodeTableUpdate = TableUpdate <$> string <*> list decodeTableUpdateRows

decodeQuerySetUpdate :: Decoder QuerySetUpdate
decodeQuerySetUpdate = QuerySetUpdate <$> u32 <*> list decodeTableUpdate

decodeReducerOutcome :: Decoder ReducerOutcome
decodeReducerOutcome = sumD $ \t -> case t of
  0 -> Right (OutcomeOk <$> bytes <*> list decodeQuerySetUpdate)
  1 -> Right (pure OutcomeOkEmpty)
  2 -> Right (OutcomeErr <$> bytes)
  3 -> Right (OutcomeInternalError <$> string)
  _ -> Left (UnknownVariant t)

decodeProcedureStatus :: Decoder ProcedureStatus
decodeProcedureStatus = sumD $ \t -> case t of
  0 -> Right (ProcReturned <$> bytes)
  1 -> Right (ProcInternalError <$> string)
  _ -> Left (UnknownVariant t)

decodeServerMessage :: Decoder ServerMessage
decodeServerMessage = sumD $ \t -> case t of
  0 -> Right (InitialConnection <$> decodeIdentity <*> decodeConnectionId <*> string)
  1 -> Right (SubscribeApplied <$> u32 <*> u32 <*> decodeQueryRows)
  2 -> Right (UnsubscribeApplied <$> u32 <*> u32 <*> optional decodeQueryRows)
  3 -> Right (SubscriptionError <$> optional u32 <*> u32 <*> string)
  4 -> Right (TransactionUpdate <$> list decodeQuerySetUpdate)
  5 -> Right (OneOffQueryResult <$> u32 <*> result string decodeQueryRows)
  6 -> Right (ReducerResult <$> u32 <*> decodeTimestamp <*> decodeReducerOutcome)
  7 -> Right (ProcedureResult <$> decodeProcedureStatus <*> decodeTimestamp
                              <*> decodeTimeDuration <*> u32)
  _ -> Right (pure (Unhandled t))

data ClientMessage
  = Subscribe Word32 Word32 [Text]
  | Unsubscribe Word32 Word32 Word8
  | OneOffQuery Word32 Text
  | CallReducer Word32 Word8 Text ByteString
  | CallProcedure Word32 Word8 Text ByteString
  deriving (Eq, Show)

encodeSubscribe :: Word32 -> Word32 -> [Text] -> B.Builder
encodeSubscribe rid qsid qs =
  encodeSum 0 (encodeU32 rid <> encodeU32 qsid <> encodeList qs encodeString)

encodeUnsubscribe :: Word32 -> Word32 -> Word8 -> B.Builder
encodeUnsubscribe rid qsid flags =
  encodeSum 1 (encodeU32 rid <> encodeU32 qsid <> encodeU8 flags)

encodeOneOffQuery :: Word32 -> Text -> B.Builder
encodeOneOffQuery rid q = encodeSum 2 (encodeU32 rid <> encodeString q)

encodeCallReducer :: Word32 -> Word8 -> Text -> ByteString -> B.Builder
encodeCallReducer rid flags name args =
  encodeSum 3 (encodeU32 rid <> encodeU8 flags <> encodeString name <> encodeBytes args)

encodeCallProcedure :: Word32 -> Word8 -> Text -> ByteString -> B.Builder
encodeCallProcedure rid flags name args =
  encodeSum 4 (encodeU32 rid <> encodeU8 flags <> encodeString name <> encodeBytes args)

encodeClientMessage :: ClientMessage -> B.Builder
encodeClientMessage m = case m of
  Subscribe rid qsid qs -> encodeSubscribe rid qsid qs
  Unsubscribe rid qsid flags -> encodeUnsubscribe rid qsid flags
  OneOffQuery rid q -> encodeOneOffQuery rid q
  CallReducer rid f name args -> encodeCallReducer rid f name args
  CallProcedure rid f name args -> encodeCallProcedure rid f name args
