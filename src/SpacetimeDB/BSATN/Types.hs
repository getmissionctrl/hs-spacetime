module SpacetimeDB.BSATN.Types
  ( Identity, identityFromInteger, identityToInteger, identityToHex
  , decodeIdentity, encodeIdentity
  , ConnectionId, connectionIdFromInteger, connectionIdToInteger, connectionIdToHex
  , decodeConnectionId, encodeConnectionId
  , Timestamp (..), decodeTimestamp, encodeTimestamp
  , TimeDuration (..), decodeTimeDuration, encodeTimeDuration
  , Uuid (..), decodeUuid, encodeUuid
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.WideWord (Word128, Word256)
import Numeric (showHex)
import SpacetimeDB.BSATN.Decoder
import SpacetimeDB.BSATN.Encoder

newtype Identity = Identity Word256 deriving (Eq, Ord, Show)
identityFromInteger :: Integer -> Identity
identityFromInteger = Identity . fromInteger
identityToInteger :: Identity -> Integer
identityToInteger (Identity w) = toInteger w
identityToHex :: Identity -> Text
identityToHex (Identity w) = T.pack (pad 64 (showHex (toInteger w) ""))
decodeIdentity :: Decoder Identity
decodeIdentity = Identity <$> u256
encodeIdentity :: Encoder Identity
encodeIdentity (Identity w) = encodeU256 w

newtype ConnectionId = ConnectionId Word128 deriving (Eq, Ord, Show)
connectionIdFromInteger :: Integer -> ConnectionId
connectionIdFromInteger = ConnectionId . fromInteger
connectionIdToInteger :: ConnectionId -> Integer
connectionIdToInteger (ConnectionId w) = toInteger w
connectionIdToHex :: ConnectionId -> Text
connectionIdToHex (ConnectionId w) = T.pack (pad 32 (showHex (toInteger w) ""))
decodeConnectionId :: Decoder ConnectionId
decodeConnectionId = ConnectionId <$> u128
encodeConnectionId :: Encoder ConnectionId
encodeConnectionId (ConnectionId w) = encodeU128 w

newtype Timestamp = Timestamp Int64 deriving (Eq, Ord, Show)
decodeTimestamp :: Decoder Timestamp
decodeTimestamp = Timestamp <$> i64
encodeTimestamp :: Encoder Timestamp
encodeTimestamp (Timestamp v) = encodeI64 v

newtype TimeDuration = TimeDuration Int64 deriving (Eq, Ord, Show)
decodeTimeDuration :: Decoder TimeDuration
decodeTimeDuration = TimeDuration <$> i64
encodeTimeDuration :: Encoder TimeDuration
encodeTimeDuration (TimeDuration v) = encodeI64 v

newtype Uuid = Uuid Word128 deriving (Eq, Ord, Show)
decodeUuid :: Decoder Uuid
decodeUuid = Uuid <$> u128
encodeUuid :: Encoder Uuid
encodeUuid (Uuid w) = encodeU128 w

pad :: Int -> String -> String
pad n s = replicate (n - length s) '0' ++ s
