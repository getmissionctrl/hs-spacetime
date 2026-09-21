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
reducers as Haskell values and emit the exact BSATN bytes the host expects.
Byte-for-byte validated against captured Rust goldens (@event@, @person@,
@widget@; the last covers primary key / auto-inc / index / unique constraint /
sequence / lifecycle reducer).
-}
module SpacetimeDB.Server.Schema
  ( AlgType (..)
  , Field (..)
  , Lifecycle (..)
  , TableType (..)
  , TableAccess (..)
  , IndexDef (..)
  , ConstraintDef (..)
  , SequenceDef (..)
  , ReducerSchema (..)
  , TypeDefSchema (..)
  , TableSchema (..)
  , ModuleSchema (..)
  , encodeModule
  , encodeAlgType
  ) where

import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import Data.Word (Word16, Word32, Word8)
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

-- | Special roles a reducer can play in the module lifecycle.
data Lifecycle = Init | OnConnect | OnDisconnect
  deriving stock (Eq, Show, Generic)

data TableType = SystemTable | UserTable
  deriving stock (Eq, Show, Generic)

data TableAccess = PublicTable | PrivateTable
  deriving stock (Eq, Show, Generic)

{- | A BTree index over the given columns. @sourceName@ follows the convention
@{table}_{cols}_idx_btree@; @accessorName@ is the column accessor name.
-}
data IndexDef = IndexDef
  { sourceName :: !(Maybe Text)
  , accessorName :: !(Maybe Text)
  , columns :: ![Word16]
  }
  deriving stock (Eq, Show, Generic)

-- | A unique constraint over the given columns.
data ConstraintDef = ConstraintDef
  { sourceName :: !(Maybe Text)
  , uniqueColumns :: ![Word16]
  }
  deriving stock (Eq, Show, Generic)

-- | An auto-increment sequence on a column.
data SequenceDef = SequenceDef
  { sourceName :: !(Maybe Text)
  , column :: !Word16
  , start :: !(Maybe Integer)
  , minValue :: !(Maybe Integer)
  , maxValue :: !(Maybe Integer)
  , increment :: !Integer
  }
  deriving stock (Eq, Show, Generic)

data ReducerSchema = ReducerSchema
  { name :: !Text
  , params :: ![Field]
  , lifecycle :: !(Maybe Lifecycle)
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
  , primaryKey :: ![Word16]
  , indexes :: ![IndexDef]
  , constraints :: ![ConstraintDef]
  , sequences :: ![SequenceDef]
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

{- | The V10 sections, in the order the Rust builder emits them so the output
byte-matches captured goldens.

@RawModuleDefV10@ is a @Vec\<Section>@ whose order is arbitrary; the Rust builder
appends each section the first time it is touched (find-or-append). Replaying that
first-touch order against the captured goldens gives: a lifecycle reducer touches
@[LifeCycleReducers, Reducers, ExplicitNames]@ (in that order), a plain reducer
touches @[Reducers, ExplicitNames]@, then tables/types touch @[Typespace, Types,
Tables]@. So the only thing that moves is the LifeCycleReducers section, which lands
before Reducers exactly when the first declared reducer is a lifecycle reducer (it
creates that section before any plain reducer creates the Reducers section), and
after ExplicitNames otherwise. It is absent when no reducer has a lifecycle role.
-}
sections :: ModuleSchema -> [B.Builder]
sections m =
  reducerSections
    ++ [ encodeSum 0 (encodeList m.typespace encodeAlgType) -- Typespace
       , encodeSum 1 (encodeList m.types encodeTypeDef) -- Types
       , encodeSum 2 (encodeList m.tables encodeTable) -- Tables
       ]
 where
  reducersSection = encodeSum 3 (encodeList m.reducers encodeReducer) -- Reducers
  explicitNamesSection = encodeSum 10 (encodeU32 0) -- ExplicitNames { entries: [] }
  lcs = mapMaybe (\r -> (\lc -> (lc, r.name)) <$> r.lifecycle) m.reducers
  lifecycleSection = encodeSum 7 (encodeList lcs encodeLifecycleEntry)
  headIsLifecycle = case m.reducers of
    (r : _) -> isJust r.lifecycle
    [] -> False
  reducerSections
    | null lcs = [reducersSection, explicitNamesSection]
    | headIsLifecycle = [lifecycleSection, reducersSection, explicitNamesSection]
    | otherwise = [reducersSection, explicitNamesSection, lifecycleSection]
  encodeLifecycleEntry (lc, nm) = encodeU8 (lifecycleTag lc) <> encodeString nm

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

-- Lifecycle reducers are Private; all others are ClientCallable.
encodeReducer :: Encoder ReducerSchema
encodeReducer r =
  encodeString r.name
    <> encodeList r.params encodeField -- params : ProductType
    <> encodeU8 (maybe 1 (const 0) r.lifecycle) -- FunctionVisibility: ClientCallable=1 / Private=0
    <> encodeAlgType (TProduct []) -- ok_return_type = unit
    <> encodeAlgType TString -- err_return_type = String

encodeTypeDef :: Encoder TypeDefSchema
encodeTypeDef t =
  encodeList t.scope encodeString -- RawScopedTypeName.scope
    <> encodeString t.name
    <> encodeU32 t.ref
    <> encodeBool t.customOrdering

encodeTable :: Encoder TableSchema
encodeTable tb =
  encodeString tb.name
    <> encodeU32 tb.productTypeRef
    <> encodeColList tb.primaryKey
    <> encodeList tb.indexes encodeIndex
    <> encodeList tb.constraints encodeConstraint
    <> encodeList tb.sequences encodeSequence
    <> encodeU8 (tableTypeTag tb.tableType)
    <> encodeU8 (tableAccessTag tb.tableAccess)
    <> encodeU32 0 -- default_values
    <> encodeBool tb.isEvent

-- | A @ColList@ serialises as a u32 count followed by one u16 per column.
encodeColList :: Encoder [Word16]
encodeColList cols = encodeList cols encodeU16

encodeIndex :: Encoder IndexDef
encodeIndex ix =
  encodeOptional ix.sourceName encodeString
    <> encodeOptional ix.accessorName encodeString
    <> encodeSum 0 (encodeColList ix.columns) -- RawIndexAlgorithm::BTree

encodeConstraint :: Encoder ConstraintDef
encodeConstraint c =
  encodeOptional c.sourceName encodeString
    <> encodeSum 0 (encodeColList c.uniqueColumns) -- RawConstraintData::Unique

encodeSequence :: Encoder SequenceDef
encodeSequence sq =
  encodeOptional sq.sourceName encodeString
    <> encodeU16 sq.column
    <> encodeOptional sq.start encodeI128Integer
    <> encodeOptional sq.minValue encodeI128Integer
    <> encodeOptional sq.maxValue encodeI128Integer
    <> encodeI128Integer sq.increment

-- | Encode an 'Integer' as a 16-byte little-endian i128 (two's complement wrap).
encodeI128Integer :: Encoder Integer
encodeI128Integer n = mconcat [B.word8 (fromIntegral ((m `shiftR` (8 * i)) .&. 0xff)) | i <- [0 .. 15]]
 where
  m = n `mod` (2 ^ (128 :: Int))

lifecycleTag :: Lifecycle -> Word8
lifecycleTag Init = 0
lifecycleTag OnConnect = 1
lifecycleTag OnDisconnect = 2

tableTypeTag :: TableType -> Word8
tableTypeTag SystemTable = 0
tableTypeTag UserTable = 1

tableAccessTag :: TableAccess -> Word8
tableAccessTag PublicTable = 0
tableAccessTag PrivateTable = 1
