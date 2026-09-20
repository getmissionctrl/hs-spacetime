{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

{- | Schema IR + BSATN encoder for the module description that
@__describe_module__@ must return: @RawModuleDef::V10@ (see the
@spacetimedb-lib@ @db::raw_def::v10@ module).

The encoded form is a versioned sum (@V10@ = tag 2) wrapping a
@Vec\<RawModuleDefV10Section\>@. This module lets an author describe tables and
reducers as Haskell values and emit the exact BSATN bytes the host expects,
replacing the Phase-1 approach of embedding schema bytes captured from a Rust
fixture. Byte-for-byte validated against the captured goldens (see SchemaSpec).

Scope of this first cut: plain tables (no primary key / indexes / constraints /
sequences / column defaults). Those add non-empty @ColList@ and def vecs and are
layered on next, validated by the @widget@ golden.
-}
module SpacetimeDB.Server.Schema
  ( AlgType (..)
  , Field (..)
  , Visibility (..)
  , TableType (..)
  , TableAccess (..)
  , ReducerSchema (..)
  , TypeDefSchema (..)
  , TableSchema (..)
  , ModuleSchema (..)
  , encodeModule
  , encodeAlgType
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import Data.Text (Text)
import Data.Word (Word32, Word8)
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Encoder

{- | A SATS 'AlgebraicType'. Constructor order mirrors the Rust enum, whose index
is the BSATN sum tag: Ref=0, Sum=1, Product=2, Array=3, String=4, Bool=5,
I8=6 … F64=19.
-}
data AlgType
  = TRef Word32
  | TSum [Field]
  | TProduct [Field]
  | TArray AlgType
  | TString
  | TBool
  | TI8
  | TU8
  | TI16
  | TU16
  | TI32
  | TU32
  | TI64
  | TU64
  | TI128
  | TU128
  | TI256
  | TU256
  | TF32
  | TF64
  deriving stock (Eq, Show, Generic)

-- | A product/sum element: an optional name and its type.
data Field = Field
  { name :: !(Maybe Text)
  , ty :: !AlgType
  }
  deriving stock (Eq, Show, Generic)

data Visibility = Private | ClientCallable
  deriving stock (Eq, Show, Generic)

data TableType = SystemTable | UserTable
  deriving stock (Eq, Show, Generic)

data TableAccess = PublicTable | PrivateTable
  deriving stock (Eq, Show, Generic)

data ReducerSchema = ReducerSchema
  { name :: !Text
  , params :: ![Field]
  , visibility :: !Visibility
  , okType :: !AlgType
  , errType :: !AlgType
  }
  deriving stock (Eq, Show, Generic)

data TypeDefSchema = TypeDefSchema
  { scope :: ![Text]
  , name :: !Text
  , ref :: !Word32
  , customOrdering :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data TableSchema = TableSchema
  { name :: !Text
  , productTypeRef :: !Word32
  , tableType :: !TableType
  , tableAccess :: !TableAccess
  , isEvent :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data ModuleSchema = ModuleSchema
  { typespace :: ![AlgType]
  , types :: ![TypeDefSchema]
  , tables :: ![TableSchema]
  , reducers :: ![ReducerSchema]
  }
  deriving stock (Eq, Show, Generic)

-- | Emit the full @RawModuleDef::V10@ BSATN bytes for a module description.
encodeModule :: ModuleSchema -> BS.ByteString
encodeModule m = runEncoder id (encodeSum 2 (encodeList (sections m) id))

{- | The V10 sections, in the same order the Rust builder emits them so the
output byte-matches captured goldens (the host itself decodes by tag, so the
order is not semantically required).
-}
sections :: ModuleSchema -> [B.Builder]
sections m =
  [ encodeSum 3 (encodeList m.reducers encodeReducer) -- Reducers
  , encodeSum 10 (encodeU32 0) -- ExplicitNames { entries: [] }
  , encodeSum 0 (encodeList m.typespace encodeAlgType) -- Typespace
  , encodeSum 1 (encodeList m.types encodeTypeDef) -- Types
  , encodeSum 2 (encodeList m.tables encodeTable) -- Tables
  ]

encodeAlgType :: Encoder AlgType
encodeAlgType t = case t of
  TRef i -> encodeSum 0 (encodeU32 i)
  TSum fs -> encodeSum 1 (encodeList fs encodeField)
  TProduct fs -> encodeSum 2 (encodeList fs encodeField)
  TArray e -> encodeSum 3 (encodeAlgType e)
  TString -> prim 4
  TBool -> prim 5
  TI8 -> prim 6
  TU8 -> prim 7
  TI16 -> prim 8
  TU16 -> prim 9
  TI32 -> prim 10
  TU32 -> prim 11
  TI64 -> prim 12
  TU64 -> prim 13
  TI128 -> prim 14
  TU128 -> prim 15
  TI256 -> prim 16
  TU256 -> prim 17
  TF32 -> prim 18
  TF64 -> prim 19
 where
  prim n = encodeSum n mempty

encodeField :: Encoder Field
encodeField f = encodeOptional f.name encodeString <> encodeAlgType f.ty

encodeReducer :: Encoder ReducerSchema
encodeReducer r =
  encodeString r.name
    <> encodeList r.params encodeField -- params : ProductType
    <> encodeU8 (visibilityTag r.visibility)
    <> encodeAlgType r.okType
    <> encodeAlgType r.errType

encodeTypeDef :: Encoder TypeDefSchema
encodeTypeDef t =
  encodeList t.scope encodeString -- RawScopedTypeName.scope
    <> encodeString t.name
    <> encodeU32 t.ref
    <> encodeBool t.customOrdering

{- | Plain-table encoding: empty primary_key/indexes/constraints/sequences and
default_values. TODO: real @ColList@ + these vecs for PK/auto_inc (widget).
-}
encodeTable :: Encoder TableSchema
encodeTable tb =
  encodeString tb.name
    <> encodeU32 tb.productTypeRef
    <> encodeU32 0 -- primary_key : ColList (empty)
    <> encodeU32 0 -- indexes
    <> encodeU32 0 -- constraints
    <> encodeU32 0 -- sequences
    <> encodeU8 (tableTypeTag tb.tableType)
    <> encodeU8 (tableAccessTag tb.tableAccess)
    <> encodeU32 0 -- default_values
    <> encodeBool tb.isEvent

visibilityTag :: Visibility -> Word8
visibilityTag Private = 0
visibilityTag ClientCallable = 1

tableTypeTag :: TableType -> Word8
tableTypeTag SystemTable = 0
tableTypeTag UserTable = 1

tableAccessTag :: TableAccess -> Word8
tableAccessTag PublicTable = 0
tableAccessTag PrivateTable = 1
