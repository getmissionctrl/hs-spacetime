{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

{- | Assemble a runnable module from typed tables and reducers. 'defineModule'
derives the full @RawModuleDef::V10@ schema bytes (via 'SpacetimeType' +
"SpacetimeDB.Server.Schema") and the ordered dispatch list the runtime needs —
so an author defines tables as Haskell types and reducers as typed handlers, and
never writes schema bytes or wires reducer ids by hand.

@
theModule = defineModule
  [ tableWith widgetTable [PrimaryKey \"id\", AutoInc \"id\"] ]
  [ reducerReg \"add_widget\" (\\(AddWidgetArgs name qty) -> ...)
  , lifecycleReg Init \"init\" (\\() -> ...) ]
@

Reducer order in the emitted schema matches the dispatch list order, so name→id
dispatch is correct by construction. A 'PrimaryKey' column produces the matching
BTree index (@{table}_{col}_idx_btree@) + unique constraint; 'AutoInc' produces
the auto-increment sequence.
-}
module SpacetimeDB.Server.Module
  ( TableReg
  , tableReg
  , tableWith
  , Column
  , ColumnAttr (..)
  , ReducerReg
  , reducerReg
  , lifecycleReg
  , Lifecycle (..)
  , Reducer
  , reducer
  , reducerName
  , defineModule
  ) where

import Data.List (findIndex)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Typeable (Typeable, tyConName, typeRep, typeRepTyCon)
import Data.Word (Word16)
import GHC.OverloadedLabels (IsLabel (..))
import GHC.Records (HasField)
import GHC.TypeLits (KnownSymbol, symbolVal)
import SpacetimeDB.BSATN.Decoder (Decoder)
import SpacetimeDB.Server.Internal (BoundReducer (..), ModuleDef (..), ReducerM)
import SpacetimeDB.Server.Reducer (Reducer, reducer, reducerName)
import SpacetimeDB.Server.Schema
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Table (Table, tableName)

{- | A column of @row@, referenced by field name via an overloaded label (e.g.
@#id@). The 'IsLabel' instance requires @row@ to actually have that field, so a
mis-typed column name is a compile error rather than a silent runtime fallback.
-}
newtype Column row = Column Text
  deriving stock (Eq, Show)

instance (HasField name row ty, KnownSymbol name) => IsLabel name (Column row) where
  fromLabel = Column (T.pack (symbolVal (Proxy @name)))

-- | A per-column table attribute, referencing an existing column of @row@.
data ColumnAttr row
  = PrimaryKey (Column row)
  | AutoInc (Column row)
  deriving stock (Eq, Show)

{- | A table registered into a module, with any column attributes. Its row type
is a 'SpacetimeType' (schema + row codec) and 'Typeable' (exported type name).
-}
data TableReg = forall row. (SpacetimeType row, Typeable row) => TableReg (Table row) [ColumnAttr row]

{- | A reducer registered into a module: a name, optional lifecycle role, and a
typed handler.
-}
data ReducerReg = forall args. (SpacetimeType args) => ReducerReg Text (Maybe Lifecycle) (args -> ReducerM ())

-- | Register a plain table (no primary key / auto-inc).
tableReg :: (SpacetimeType row, Typeable row) => Table row -> TableReg
tableReg t = TableReg t []

-- | Register a table with column attributes (primary key, auto-inc).
tableWith :: (SpacetimeType row, Typeable row) => Table row -> [ColumnAttr row] -> TableReg
tableWith = TableReg

-- | Register a client-callable reducer from its typed handle.
reducerReg :: (SpacetimeType args) => Reducer args -> (args -> ReducerM ()) -> ReducerReg
reducerReg red = ReducerReg (reducerName red) Nothing

-- | Register a lifecycle reducer (Init / OnConnect / OnDisconnect).
lifecycleReg :: (SpacetimeType args) => Lifecycle -> Reducer args -> (args -> ReducerM ()) -> ReducerReg
lifecycleReg lc red = ReducerReg (reducerName red) (Just lc)

-- | Build a module: derive schema bytes + the ordered dispatch list.
defineModule :: [TableReg] -> [ReducerReg] -> ModuleDef
defineModule tbls rdcrs =
  ModuleDef
    { schemaBytes = encodeModule schema
    , reducers = map toReducer rdcrs
    }
 where
  schema =
    ModuleSchema
      { typespace = map tableRowType tbls
      , types = zipWith tableTypeDef [0 ..] tbls
      , tables = zipWith tableDef [0 ..] tbls
      , reducers = map reducerSchema rdcrs
      }

  tableRowType (TableReg t _) = rowAlgType t
  tableTypeDef i (TableReg t _) =
    TypeDefSchema {scope = [], name = rowTypeName t, ref = i, customOrdering = True}
  tableDef i (TableReg t attrs) =
    let fields = rowFields t
        tname = tableName t
        colOf c = colIndex fields c
        pkCols = [colOf c | PrimaryKey (Column c) <- attrs]
     in TableSchema
          { name = tname
          , productTypeRef = i
          , primaryKey = pkCols
          , indexes =
              [ IndexDef
                  { sourceName = Just (tname <> "_" <> c <> "_idx_btree")
                  , accessorName = Just c
                  , columns = [colOf c]
                  }
              | PrimaryKey (Column c) <- attrs
              ]
          , constraints = [ConstraintDef {sourceName = Nothing, uniqueColumns = [colOf c]} | PrimaryKey (Column c) <- attrs]
          , sequences =
              [ SequenceDef
                  { sourceName = Nothing
                  , column = colOf c
                  , start = Nothing
                  , minValue = Nothing
                  , maxValue = Nothing
                  , increment = 1
                  }
              | AutoInc (Column c) <- attrs
              ]
          , tableType = UserTable
          , tableAccess = PublicTable
          , isEvent = False
          }
  reducerSchema (ReducerReg nm lc h) =
    ReducerSchema {name = nm, params = paramFields (handlerArgType h), lifecycle = lc}
  toReducer (ReducerReg _ _ h) = BoundReducer (handlerDecoder h) h

-- Recover per-type info from the (phantom/argument) type of an existential field.
rowAlgType :: forall row. (SpacetimeType row) => Table row -> AlgType
rowAlgType _ = algebraicType @row

rowFields :: forall row. (SpacetimeType row) => Table row -> [Field]
rowFields _ = case algebraicType @row of
  TProduct fs -> fs
  _ -> []

rowTypeName :: forall row. (Typeable row) => Table row -> Text
rowTypeName _ = T.pack (tyConName (typeRepTyCon (typeRep (Proxy @row))))

handlerArgType :: forall args. (SpacetimeType args) => (args -> ReducerM ()) -> AlgType
handlerArgType _ = algebraicType @args

handlerDecoder :: forall args. (SpacetimeType args) => (args -> ReducerM ()) -> Decoder args
handlerDecoder _ = decodeVal @args

-- | A reducer's parameters are the fields of its argument product.
paramFields :: AlgType -> [Field]
paramFields (TProduct fs) = fs
paramFields other = [Field Nothing other]

-- | The 0-based column index of a named field (0 if absent — a misuse).
colIndex :: [Field] -> Text -> Word16
colIndex fields nm = fromIntegral (fromMaybe 0 (findIndex (\f -> f.name == Just nm) fields))
