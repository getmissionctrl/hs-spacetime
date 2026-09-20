{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Assemble a runnable module from typed tables and reducers. 'defineModule'
derives the full @RawModuleDef::V10@ schema bytes (via 'SpacetimeType' +
"SpacetimeDB.Server.Schema") and the ordered dispatch list the runtime needs —
so an author defines tables as Haskell types and reducers as typed handlers, and
never writes schema bytes or wires reducer ids by hand.

@
theModule :: ModuleDef
theModule = defineModule
  [ tableReg eventTable ]
  [ reducerReg \"record\" (\\(RecordArgs note) -> ...)
  , reducerReg \"delete_all\" (\\() -> ...) ]
@

Reducer order in the emitted schema matches the dispatch list order, so name→id
dispatch is correct by construction. Scope: plain public user tables (see
"SpacetimeDB.Server.Schema").
-}
module SpacetimeDB.Server.Module
  ( TableReg
  , tableReg
  , ReducerReg
  , reducerReg
  , defineModule
  ) where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Typeable (Typeable, tyConName, typeRep, typeRepTyCon)
import SpacetimeDB.BSATN.Decoder (Decoder)
import SpacetimeDB.Server.Internal (ModuleDef (..), Reducer (..), ReducerM)
import SpacetimeDB.Server.Schema
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Table (Table, tableName)

{- | A table registered into a module: its row type is a 'SpacetimeType' (for the
schema + row codec) and 'Typeable' (for the exported type name).
-}
data TableReg = forall row. (SpacetimeType row, Typeable row) => TableReg (Table row)

-- | A reducer registered into a module: a name and a typed handler.
data ReducerReg = forall args. (SpacetimeType args) => ReducerReg Text (args -> ReducerM ())

tableReg :: (SpacetimeType row, Typeable row) => Table row -> TableReg
tableReg = TableReg

reducerReg :: (SpacetimeType args) => Text -> (args -> ReducerM ()) -> ReducerReg
reducerReg = ReducerReg

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

  tableRowType (TableReg t) = rowAlgType t
  tableTypeDef i (TableReg t) =
    TypeDefSchema {scope = [], name = rowTypeName t, ref = i, customOrdering = True}
  tableDef i (TableReg t) =
    TableSchema
      { name = tableName t
      , productTypeRef = i
      , tableType = UserTable
      , tableAccess = PublicTable
      , isEvent = False
      }
  reducerSchema (ReducerReg nm h) =
    ReducerSchema
      { name = nm
      , params = paramFields (handlerArgType h)
      , visibility = ClientCallable
      , okType = TProduct []
      , errType = TString
      }
  toReducer (ReducerReg _ h) = Reducer (handlerDecoder h) h

-- Recover per-type info from the (phantom/argument) type of an existential field.
rowAlgType :: forall row. (SpacetimeType row) => Table row -> AlgType
rowAlgType _ = algebraicType @row

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
