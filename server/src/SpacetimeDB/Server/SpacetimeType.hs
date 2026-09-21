{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{- | 'SpacetimeType' ties a Haskell type to its SATS 'AlgType' and its BSATN row
codec, with the invariant that the three agree. A single-constructor record gets
all three for free via 'GHC.Generics':

@
data Event = Event { who :: Text, at :: Int64 }
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)
@

yields @algebraicType \@Event == TProduct [Field (Just \"who\") TString, Field
(Just \"at\") TI64]@ and a matching @encodeVal@/@decodeVal@. This is what lets an
author define a table by declaring a Haskell type. Field order is declaration
order, consistent between the type description and the codec.
-}
module SpacetimeDB.Server.SpacetimeType
  ( SpacetimeType (..)
  ) where

import qualified Data.ByteString.Builder as B
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16, Word32, Word64, Word8)
import GHC.Generics
import SpacetimeDB.BSATN.Decoder
import SpacetimeDB.BSATN.Encoder
import SpacetimeDB.BSATN.Types
  ( ConnectionId
  , Identity
  , Timestamp
  , decodeConnectionId
  , decodeIdentity
  , decodeTimestamp
  , encodeConnectionId
  , encodeIdentity
  , encodeTimestamp
  )
import SpacetimeDB.Server.Schema (AlgType (..), Field (..))

class SpacetimeType a where
  -- | The SATS type describing @a@ (for the module typespace).
  algebraicType :: AlgType

  -- | BSATN row/value encoder for @a@.
  encodeVal :: a -> B.Builder

  -- | BSATN row/value decoder for @a@.
  decodeVal :: Decoder a

  default algebraicType :: (Generic a, GProd (Rep a)) => AlgType
  algebraicType = TProduct (gFields @(Rep a))

  default encodeVal :: (Generic a, GProd (Rep a)) => a -> B.Builder
  encodeVal = gEncode . from

  default decodeVal :: (Generic a, GProd (Rep a)) => Decoder a
  decodeVal = to <$> gDecode

-- Leaf (primitive) instances: map directly onto the bsatn combinators.

-- | The empty product — used for no-argument reducers.
instance SpacetimeType () where
  algebraicType = TProduct []
  encodeVal _ = mempty
  decodeVal = pure ()

instance SpacetimeType Bool where
  algebraicType = TBool
  encodeVal = encodeBool
  decodeVal = bool

instance SpacetimeType Text where
  algebraicType = TString
  encodeVal = encodeString
  decodeVal = string

instance SpacetimeType Word8 where
  algebraicType = TU8
  encodeVal = encodeU8
  decodeVal = u8

instance SpacetimeType Word16 where
  algebraicType = TU16
  encodeVal = encodeU16
  decodeVal = u16

instance SpacetimeType Word32 where
  algebraicType = TU32
  encodeVal = encodeU32
  decodeVal = u32

instance SpacetimeType Word64 where
  algebraicType = TU64
  encodeVal = encodeU64
  decodeVal = u64

instance SpacetimeType Int8 where
  algebraicType = TI8
  encodeVal = encodeI8
  decodeVal = i8

instance SpacetimeType Int16 where
  algebraicType = TI16
  encodeVal = encodeI16
  decodeVal = i16

instance SpacetimeType Int32 where
  algebraicType = TI32
  encodeVal = encodeI32
  decodeVal = i32

instance SpacetimeType Int64 where
  algebraicType = TI64
  encodeVal = encodeI64
  decodeVal = i64

instance SpacetimeType Float where
  algebraicType = TF32
  encodeVal = encodeF32
  decodeVal = f32

instance SpacetimeType Double where
  algebraicType = TF64
  encodeVal = encodeF64
  decodeVal = f64

-- Special scalar types: SpacetimeDB represents each inline as a single-field
-- product with a reserved marker field name. The value BSATN reuses the existing
-- codecs from "SpacetimeDB.BSATN.Types".

instance SpacetimeType Identity where
  algebraicType = TProduct [Field (Just "__identity__") TU256]
  encodeVal = encodeIdentity
  decodeVal = decodeIdentity

instance SpacetimeType Timestamp where
  algebraicType = TProduct [Field (Just "__timestamp_micros_since_unix_epoch__") TI64]
  encodeVal = encodeTimestamp
  decodeVal = decodeTimestamp

instance SpacetimeType ConnectionId where
  algebraicType = TProduct [Field (Just "__connection_id__") TU128]
  encodeVal = encodeConnectionId
  decodeVal = decodeConnectionId

-- | @Option<T>@ is a two-variant sum: @some@ carries the payload, @none@ is empty.
instance (SpacetimeType a) => SpacetimeType (Maybe a) where
  algebraicType = TSum [Field (Just "some") (algebraicType @a), Field (Just "none") (TProduct [])]
  encodeVal = encodeOptionalOf encodeVal
  decodeVal = optional decodeVal

-- Generic machinery over the 'Rep' of a single-constructor record.
class GProd f where
  gFields :: [Field]
  gEncode :: f p -> B.Builder
  gDecode :: Decoder (f p)

instance (GProd f) => GProd (M1 D d f) where
  gFields = gFields @f
  gEncode (M1 x) = gEncode x
  gDecode = M1 <$> gDecode

instance (GProd f) => GProd (M1 C c f) where
  gFields = gFields @f
  gEncode (M1 x) = gEncode x
  gDecode = M1 <$> gDecode

instance (Selector s, SpacetimeType c) => GProd (M1 S s (K1 i c)) where
  gFields = [Field nm (algebraicType @c)]
   where
    nm = case selName (undefined :: M1 S s (K1 i c) ()) of
      "" -> Nothing
      n -> Just (T.pack n)
  gEncode (M1 (K1 x)) = encodeVal x
  gDecode = M1 . K1 <$> decodeVal

instance (GProd f, GProd g) => GProd (f :*: g) where
  gFields = gFields @f ++ gFields @g
  gEncode (x :*: y) = gEncode x <> gEncode y
  gDecode = (:*:) <$> gDecode <*> gDecode
