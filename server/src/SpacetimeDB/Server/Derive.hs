{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{- | Derive a whole module from an @App@ record. Field names are the table/reducer
names; 'deriveApp' fills handles from selectors and 'deriveModule' lowers the
@App@ (plus a sibling handlers record) to a 'ModuleDef'.
-}
module SpacetimeDB.Server.Derive
  ( deriveApp
  , deriveModule
  , MkHandle (..)
  , camelToSnake
  ) where

import Data.Char (isUpper, toLower)
import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Typeable (Typeable, tyConName, typeRep, typeRepTyCon)
import Data.Word (Word16, Word32)
import GHC.Generics
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import SpacetimeDB.Server.HKD
  ( ColAttrVal (..)
  , GCols
  , KnownLifecycle
  , LifecycleHook
  , Row
  , View (..)
  , columnsOf
  , lifecycleHook
  , lifecycleHookName
  , lifecycleVal
  )
import SpacetimeDB.Server.Internal (BoundReducer (..), ModuleDef (..), ReducerM)
import SpacetimeDB.Server.Reducer (Reducer, reducer, reducerName)
import SpacetimeDB.Server.Schema
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Table (Table, table, tableName)

-- | Build a handle of type @t@ from a wire name.
class MkHandle t where
  mkHandle :: Text -> t

instance MkHandle (Table row) where
  mkHandle = table

instance MkHandle (Reducer args) where
  mkHandle = reducer

instance MkHandle (LifecycleHook l) where
  mkHandle = lifecycleHook

-- | Convert a Haskell field name to its snake_case wire name.
camelToSnake :: Text -> Text
camelToSnake = T.pack . go . T.unpack
 where
  go [] = []
  go (c : cs)
    | isUpper c = '_' : toLower c : go cs
    | otherwise = c : go cs

-- | Fill every handle field of an @App@ record from its selector name.
deriveApp :: (Generic a, GDeriveApp (Rep a)) => a
deriveApp = to gderiveApp

class GDeriveApp (rep :: Type -> Type) where
  gderiveApp :: rep x

instance (GDeriveApp f) => GDeriveApp (D1 meta f) where
  gderiveApp = M1 gderiveApp

instance (GDeriveApp f) => GDeriveApp (C1 meta f) where
  gderiveApp = M1 gderiveApp

instance (GDeriveApp a, GDeriveApp b) => GDeriveApp (a :*: b) where
  gderiveApp = gderiveApp :*: gderiveApp

instance
  (KnownSymbol name, MkHandle t)
  => GDeriveApp (S1 ('MetaSel ('Just name) su ss ds) (K1 i t))
  where
  gderiveApp = M1 (K1 (mkHandle (camelToSnake (T.pack (symbolVal (Proxy @name))))))

{- | Lower an @App@ (plus a sibling handlers record) to a runnable 'ModuleDef':
derive the schema bytes from the @App@ value.
-}
deriveModule
  :: forall app handlers
   . ( Generic app
     , Generic handlers
     , GAppTables (Rep app)
     , GAppReducers (Rep app)
     , GHandlers (Rep handlers)
     , AppSigs (Rep app) ~ HandlerSigs (Rep handlers)
     )
  => app
  -> handlers
  -> ModuleDef
deriveModule appVal handlers =
  ModuleDef
    { schemaBytes = encodeModule schema
    , reducers = gHandlers (from handlers)
    }
 where
  parts = gAppTables (from appVal)
  schema =
    ModuleSchema
      { typespace = map (.rowType) parts
      , types = zipWith (\i p -> TypeDefSchema {scope = [], name = p.typeName, ref = i, customOrdering = True}) [0 ..] parts
      , tables = zipWith (\i p -> p.tbl i) [0 ..] parts
      , reducers = gAppReducers (from appVal)
      }

-- | A table's contribution to the module schema.
data TablePart = TablePart
  { rowType :: AlgType
  -- ^ product type for the typespace
  , typeName :: Text
  -- ^ exported type name (e.g. "Widget")
  , tbl :: Word32 -> TableSchema
  -- ^ given its ref/product index
  }

-- | Collect table parts from an App value (in field order).
class GAppTables (rep :: Type -> Type) where
  gAppTables :: rep x -> [TablePart]

instance (GAppTables f) => GAppTables (D1 m f) where gAppTables (M1 x) = gAppTables x
instance (GAppTables f) => GAppTables (C1 m f) where gAppTables (M1 x) = gAppTables x
instance (GAppTables a, GAppTables b) => GAppTables (a :*: b) where
  gAppTables (a :*: b) = gAppTables a ++ gAppTables b

-- tables contribute; reducers/lifecycle contribute nothing here
instance {-# OVERLAPPABLE #-} GAppTables (S1 m (K1 i t)) where
  gAppTables _ = []

instance
  ( Generic (row 'Schema)
  , GCols (Rep (row 'Schema))
  , Typeable (row 'Value)
  )
  => GAppTables (S1 m (K1 i (Table row)))
  where
  gAppTables (M1 (K1 t)) = [tablePartFor @row (tableName t)]

tablePartFor
  :: forall (row :: Row)
   . (Generic (row 'Schema), GCols (Rep (row 'Schema)), Typeable (row 'Value))
  => Text
  -> TablePart
tablePartFor tname =
  TablePart
    { rowType = TProduct fields
    , typeName = T.pack (tyConName (typeRepTyCon (typeRep (Proxy @(row 'Value)))))
    , tbl = \ref ->
        TableSchema
          { name = tname
          , productTypeRef = ref
          , primaryKey = pkCols
          , indexes =
              [ IndexDef
                  { sourceName = Just (tname <> "_" <> cn <> "_idx_btree")
                  , accessorName = Just cn
                  , columns = [ix]
                  }
              | (ix, cn) <- pkNamed
              ]
          , constraints = [ConstraintDef {sourceName = Nothing, uniqueColumns = [ix]} | (ix, _) <- pkNamed]
          , sequences =
              [ SequenceDef
                  { sourceName = Nothing
                  , column = ix
                  , start = Nothing
                  , minValue = Nothing
                  , maxValue = Nothing
                  , increment = 1
                  }
              | (ix, _) <- autoNamed
              ]
          , tableType = UserTable
          , tableAccess = PublicTable
          , isEvent = False
          }
    }
 where
  cols = columnsOf @row
  fields = [Field (Just cn) ty | (cn, ty, _) <- cols]
  indexed = zip [0 :: Word16 ..] cols
  pkNamed = [(ix, cn) | (ix, (cn, _, attrs)) <- indexed, ColPk `elem` attrs]
  pkCols = map fst pkNamed
  autoNamed = [(ix, cn) | (ix, (cn, _, attrs)) <- indexed, ColAutoInc `elem` attrs]

-- | Collect reducer schemas from an App value (skips tables), in field order.
class GAppReducers (rep :: Type -> Type) where
  gAppReducers :: rep x -> [ReducerSchema]

instance (GAppReducers f) => GAppReducers (D1 m f) where gAppReducers (M1 x) = gAppReducers x
instance (GAppReducers f) => GAppReducers (C1 m f) where gAppReducers (M1 x) = gAppReducers x
instance (GAppReducers a, GAppReducers b) => GAppReducers (a :*: b) where
  gAppReducers (a :*: b) = gAppReducers a ++ gAppReducers b

instance {-# OVERLAPPABLE #-} GAppReducers (S1 m (K1 i t)) where
  gAppReducers _ = []

instance
  (SpacetimeType args)
  => GAppReducers (S1 m (K1 i (Reducer args)))
  where
  gAppReducers (M1 (K1 r)) =
    [ReducerSchema {name = reducerName r, params = paramFields (algebraicType @args), lifecycle = Nothing}]

instance
  (KnownLifecycle l)
  => GAppReducers (S1 m (K1 i (LifecycleHook l)))
  where
  gAppReducers (M1 (K1 h)) =
    [ReducerSchema {name = lifecycleHookName h, params = [], lifecycle = Just (lifecycleVal @l)}]

paramFields :: AlgType -> [Field]
paramFields (TProduct fs) = fs
paramFields other = [Field Nothing other]

-- | Turn a handlers record into an ordered '[BoundReducer]' (field order).
class GHandlers (rep :: Type -> Type) where
  gHandlers :: rep x -> [BoundReducer]

instance (GHandlers f) => GHandlers (D1 m f) where gHandlers (M1 x) = gHandlers x
instance (GHandlers f) => GHandlers (C1 m f) where gHandlers (M1 x) = gHandlers x
instance (GHandlers a, GHandlers b) => GHandlers (a :*: b) where
  gHandlers (a :*: b) = gHandlers a ++ gHandlers b

instance
  (SpacetimeType a)
  => GHandlers (S1 m (K1 i (a -> ReducerM ())))
  where
  gHandlers (M1 (K1 h)) = [BoundReducer (decodeVal @a) h]

-- | Append at the type level, for concatenating field signatures.
type family (xs :: [k]) ++ (ys :: [k]) :: [k] where
  '[] ++ ys = ys
  (x ': xs) ++ ys = x ': (xs ++ ys)

-- | @(name, argType)@ of each Reducer/Lifecycle field of an App rep, in order.
type family AppSigs (rep :: Type -> Type) :: [(Symbol, Type)] where
  AppSigs (D1 m f) = AppSigs f
  AppSigs (C1 m f) = AppSigs f
  AppSigs (a :*: b) = AppSigs a ++ AppSigs b
  AppSigs (S1 ('MetaSel ('Just n) su ss ds) (K1 i (Reducer a))) = '[ '(n, a)]
  AppSigs (S1 ('MetaSel ('Just n) su ss ds) (K1 i (LifecycleHook l))) = '[ '(n, ())]
  AppSigs (S1 m (K1 i (Table row))) = '[]

-- | @(name, argType)@ of each handler field, in order (arg stripped from @a -> ReducerM ()@).
type family HandlerSigs (rep :: Type -> Type) :: [(Symbol, Type)] where
  HandlerSigs (D1 m f) = HandlerSigs f
  HandlerSigs (C1 m f) = HandlerSigs f
  HandlerSigs (a :*: b) = HandlerSigs a ++ HandlerSigs b
  HandlerSigs (S1 ('MetaSel ('Just n) su ss ds) (K1 i (a -> ReducerM ()))) = '[ '(n, a)]
