{- | The module-authoring surface: HKD table rows, typed table/reducer handles,
and @App@-driven module derivation, plus the runtime entry points a wasm
reactor needs ('mkContext', 'dispatchReducer', 'describeBytes').
-}
module SpacetimeDB.Server
  ( module SpacetimeDB.Server.Types
  , module SpacetimeDB.Server.HKD
  , module SpacetimeDB.Server.Table
  , module SpacetimeDB.Server.Reducer
  , module SpacetimeDB.Server.Derive
  , mkContext
  , dispatchReducer
  , describeBytes
  ) where

import SpacetimeDB.Server.Derive
import SpacetimeDB.Server.Dispatch (describeBytes, dispatchReducer, mkContext)
import SpacetimeDB.Server.HKD
import SpacetimeDB.Server.Reducer
import SpacetimeDB.Server.Table
import SpacetimeDB.Server.Types
