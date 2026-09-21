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

{- | Example reactor exercising a primary key + auto-inc column and an @init@
lifecycle reducer, authored entirely in Haskell types: the whole module — table,
reducer, and lifecycle hook — is derived from one @App@ record.
-}
module WidgetModule where

import Data.Int (Int16)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server
import SpacetimeDB.Server.ABI (runCallReducer, runDescribe)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)

data Widget f = Widget
  { id :: Column f Word64 '[ 'Pk, 'AutoInc]
  , name :: Column f Text '[]
  , quantity :: Column f Word32 '[]
  }
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (Widget 'Value)

data AddWidgetArgs = AddWidgetArgs {name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

data App = App
  { widget :: Table Widget
  , addWidget :: Reducer AddWidgetArgs
  , init :: LifecycleHook 'Init
  }
  deriving stock (Generic)

app :: App
app = deriveApp

data Handlers = Handlers
  { addWidget :: AddWidgetArgs -> ReducerM ()
  , init :: () -> ReducerM ()
  }
  deriving stock (Generic)

-- Insert with id = 0: the auto-inc sequence assigns the real id on the host.
theModule :: ModuleDef
theModule =
  deriveModule
    app
    Handlers
      { addWidget = \(AddWidgetArgs n q) -> insertRow app.widget (Widget 0 n q)
      , init = \() -> insertRow app.widget (Widget 0 "seed" 1)
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
