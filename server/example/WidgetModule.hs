{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

{- | Example reactor exercising a primary key + auto-inc column and an @init@
lifecycle reducer, authored entirely in Haskell types.
-}
module WidgetModule where

import Data.Int (Int16)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server
import SpacetimeDB.Server.ABI (runCallReducer, runDescribe)
import SpacetimeDB.Server.Module
  ( ColumnAttr (..)
  , Lifecycle (..)
  , defineModule
  , lifecycleReg
  , reducerReg
  , tableWith
  )
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import SpacetimeDB.Server.Table (Table, insertRow, table)

data Widget = Widget {id :: Word64, name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

data AddWidgetArgs = AddWidgetArgs {name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

widgetTable :: Table Widget
widgetTable = table "widget"

-- Insert with id = 0: the auto-inc sequence assigns the real id on the host.
theModule :: ModuleDef
theModule =
  defineModule
    [tableWith widgetTable [PrimaryKey "id", AutoInc "id"]]
    [ reducerReg "add_widget" $ \(AddWidgetArgs n q) -> insertRow widgetTable (Widget 0 n q)
    , lifecycleReg Init "init" $ \() -> insertRow widgetTable (Widget 0 "seed" 1)
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
