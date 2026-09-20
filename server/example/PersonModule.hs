{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

{- | Example reactor module authored entirely in Haskell types: the table is a
record, the reducers are typed handlers, and the schema bytes are derived by
'defineModule' (no embedded/captured bytes, no hand-written BSATN).
-}
module PersonModule where

import Data.Int (Int16, Int64)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Types (Timestamp (..))
import SpacetimeDB.Server
import SpacetimeDB.Server.ABI (runCallReducer, runDescribe)
import SpacetimeDB.Server.Module (Reducer, defineModule, reducer, reducerReg, tableReg)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import SpacetimeDB.Server.Table (Table, deleteRow, insertRow, scanRows, table)

-- The table row, as a plain record.
data Event = Event {who :: Text, at :: Int64}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

-- Reducer argument products, as plain records.
newtype RecordArgs = RecordArgs {note :: Text}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

newtype RecordNArgs = RecordNArgs {count :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

eventTable :: Table Event
eventTable = table "event"

-- Type-safe reducer handles (name + argument type), declared once.
deleteAll :: Reducer ()
deleteAll = reducer "delete_all"

record :: Reducer RecordArgs
record = reducer "record"

recordN :: Reducer RecordNArgs
recordN = reducer "record_n"

{- | Reducers listed in the schema's (alphabetical) order: delete_all, record,
record_n. 'defineModule' matches dispatch ids to this order.
-}
theModule :: ModuleDef
theModule =
  defineModule
    [tableReg eventTable]
    [ reducerReg deleteAll $ \() -> do
        rows <- scanRows eventTable
        mapM_ (deleteRow eventTable) rows
    , reducerReg record $ \(RecordArgs n) -> do
        ctx <- ask
        let Timestamp micros = ctx.timestamp
        insertRow eventTable (Event n micros)
    , reducerReg recordN $ \(RecordNArgs c) ->
        if c == 0
          then throwError "count must be positive"
          else insertRow eventTable (Event "n" (fromIntegral c))
    ]

foreign export ccall hs_describe :: Word32 -> IO ()
hs_describe :: Word32 -> IO ()
hs_describe = runDescribe theModule

foreign export ccall
  hs_call_reducer
    :: Word32
    -> Word64
    -> Word64
    -> Word64
    -> Word64
    -> Word64
    -> Word64
    -> Word64
    -> Word32
    -> Word32
    -> IO Int16
hs_call_reducer
  :: Word32
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word32
  -> Word32
  -> IO Int16
hs_call_reducer = runCallReducer theModule
