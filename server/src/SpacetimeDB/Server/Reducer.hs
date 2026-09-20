{- | A type-safe reducer handle: a reducer's name paired (as a phantom) with its
argument type. Declaring a reducer as a handle, once, in the schema module shared
by server and client, means:

  * you can only call/register reducers that are declared (a typo is a scope
    error, not a runtime rejection),
  * the argument type is checked against the handle, and
  * the name string is single-sourced, so server and client cannot drift.

@
addWidget :: Reducer AddWidgetArgs
addWidget = reducer \"add_widget\"
@

The server registers it with @reducerReg addWidget handler@; the client will call
it with @callTyped conn addWidget args@ (same handle, same name, checked args).
-}
module SpacetimeDB.Server.Reducer
  ( Reducer
  , reducer
  , reducerName
  ) where

import Data.Text (Text)

-- | A reducer handle, phantom in its argument type @args@.
newtype Reducer args = Reducer Text

-- | Declare a reducer handle from its wire name.
reducer :: Text -> Reducer args
reducer = Reducer

-- | The reducer's wire name.
reducerName :: Reducer args -> Text
reducerName (Reducer n) = n
