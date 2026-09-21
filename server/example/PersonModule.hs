{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE NoFieldSelectors #-}

{- | Example reactor module authored entirely in Haskell types: the whole @event@
module — its table and three reducers — is derived from one @App@ record, and the
schema bytes are derived by 'deriveModule' (no embedded/captured bytes, no
hand-written BSATN).
-}
module PersonModule where

import Data.Int (Int16, Int64)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Types (Timestamp (..))
import SpacetimeDB.Server
import SpacetimeDB.Server.ABI (runCallReducer, runDescribe)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)

-- The table row, as an HKD record (no column attributes).
data Event f = Event {who :: Column f Text '[], at :: Column f Int64 '[]}
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (Event 'Value)

-- Reducer argument products, as plain records.
newtype RecordArgs = RecordArgs {note :: Text}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

newtype RecordNArgs = RecordNArgs {count :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

-- Field order fixes the schema (and dispatch) order: event, delete_all, record,
-- record_n.
data App = App
  { event :: Table Event
  , deleteAll :: Reducer ()
  , record :: Reducer RecordArgs
  , recordN :: Reducer RecordNArgs
  }
  deriving stock (Generic)

app :: App
app = deriveApp

data Handlers = Handlers
  { deleteAll :: () -> ReducerM ()
  , record :: RecordArgs -> ReducerM ()
  , recordN :: RecordNArgs -> ReducerM ()
  }
  deriving stock (Generic)

theModule :: ModuleDef
theModule =
  deriveModule
    app
    Handlers
      { deleteAll = \() -> do
          rows <- scanRows app.event
          mapM_ (deleteRow app.event) rows
      , record = \(RecordArgs n) -> do
          ctx <- ask
          let Timestamp micros = ctx.timestamp
          insertRow app.event (Event n micros)
      , recordN = \(RecordNArgs c) ->
          if c == 0
            then throwError "count must be positive"
            else insertRow app.event (Event "n" (fromIntegral c))
      }

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
