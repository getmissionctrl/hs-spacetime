{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{- | Higher-kinded (rel8-style) table rows: columns and their attributes live in
the row type. A 'Column' has two views — 'Value' (raw field type; attributes
erased) and 'Schema' (attributes preserved so the schema can be derived).
-}
module SpacetimeDB.Server.HKD
  ( View (..)
  , Row
  , Column
  , ColAttr (..)
  , ColInfo
  , ColAttrVal (..)
  , ColumnSpec (..)
  , ReifyAttrs (..)
  , columnsOf
  , GCols (..)
  ) where

import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics
import GHC.TypeLits (KnownSymbol, symbolVal)
import SpacetimeDB.Server.Schema (AlgType)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))

-- | The view a row is being looked at through.
data View = Value | Schema

-- | Kind of a higher-kinded row constructor, e.g. @Widget :: Row@.
type Row = View -> Type

-- | A column attribute (promoted to a type-level list per column).
data ColAttr = Pk | AutoInc

-- | Value-level mirror of 'ColAttr', produced by reflection.
data ColAttrVal = ColPk | ColAutoInc
  deriving stock (Eq, Show)

{- | The 'Schema'-view carrier for a column: preserves @a@ and @attrs@ at the
type level (its runtime value is irrelevant — schema derivation is by type).
-}
newtype ColInfo (a :: Type) (attrs :: [ColAttr]) = ColInfo ()

-- | @Column f a attrs@ is @a@ under 'Value' and a 'ColInfo' under 'Schema'.
type family Column (f :: View) (a :: Type) (attrs :: [ColAttr]) :: Type where
  Column 'Value a _ = a
  Column 'Schema a attrs = ColInfo a attrs

-- | Reflect a single 'Schema'-view field type to its 'AlgType' and attributes.
class ColumnSpec (field :: Type) where
  colAlgType :: AlgType
  colAttrs :: [ColAttrVal]

instance (SpacetimeType a, ReifyAttrs attrs) => ColumnSpec (ColInfo a attrs) where
  colAlgType = algebraicType @a
  colAttrs = reifyAttrs @attrs

-- | Reflect a type-level attribute list to values.
class ReifyAttrs (attrs :: [ColAttr]) where
  reifyAttrs :: [ColAttrVal]

instance ReifyAttrs '[] where
  reifyAttrs = []

instance (ReifyAttr a, ReifyAttrs as) => ReifyAttrs (a ': as) where
  reifyAttrs = reifyAttr @a : reifyAttrs @as

class ReifyAttr (a :: ColAttr) where
  reifyAttr :: ColAttrVal

instance ReifyAttr 'Pk where
  reifyAttr = ColPk

instance ReifyAttr 'AutoInc where
  reifyAttr = ColAutoInc

-- | Ordered columns of a row, read from its 'Schema' view: (name, type, attrs).
columnsOf
  :: forall (row :: Row)
   . (Generic (row 'Schema), GCols (Rep (row 'Schema)))
  => [(Text, AlgType, [ColAttrVal])]
columnsOf = gcols @(Rep (row 'Schema))

-- | Generic walk over a row's 'Schema'-view representation.
class GCols (rep :: Type -> Type) where
  gcols :: [(Text, AlgType, [ColAttrVal])]

instance (GCols f) => GCols (D1 meta f) where
  gcols = gcols @f

instance (GCols f) => GCols (C1 meta f) where
  gcols = gcols @f

instance (GCols a, GCols b) => GCols (a :*: b) where
  gcols = gcols @a ++ gcols @b

instance
  (KnownSymbol name, ColumnSpec t)
  => GCols (S1 ('MetaSel ('Just name) su ss ds) (K1 i t))
  where
  gcols = [(T.pack (symbolVal (Proxy @name)), colAlgType @t, colAttrs @t)]
