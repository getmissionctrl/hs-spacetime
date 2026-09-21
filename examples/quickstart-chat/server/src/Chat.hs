-- | The quickstart-chat example SpacetimeDB module.
module Chat
  ( User (..)
  , Message (..)
  , SetNameArgs (..)
  , SendMessageArgs (..)
  , App (..)
  , app
  , chatModule
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Types (Identity, Timestamp)
import SpacetimeDB.Server (ModuleDef, ask, deriveApp, insertRow, throwError)
import SpacetimeDB.Server.Derive (deriveModule)
import SpacetimeDB.Server.HKD
  ( ColAttr (..)
  , Column
  , Lifecycle (..)
  , LifecycleHook
  , View (..)
  )
import SpacetimeDB.Server.Internal (ReducerContext (..))
import SpacetimeDB.Server.Reducer (Reducer)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Table (Table)
import SpacetimeDB.Server.Types (ReducerM)

data User f = User
  { identity :: Column f Identity '[ 'Pk]
  , name :: Column f (Maybe Text) '[]
  , online :: Column f Bool '[]
  }
  deriving stock (Generic)

deriving anyclass instance SpacetimeType (User 'Value)

deriving stock instance Eq (User 'Value)

deriving stock instance Show (User 'Value)

data Message f = Message
  { sender :: Column f Identity '[]
  , sent :: Column f Timestamp '[]
  , text :: Column f Text '[]
  }
  deriving stock (Generic)

deriving anyclass instance SpacetimeType (Message 'Value)

deriving stock instance Eq (Message 'Value)

deriving stock instance Show (Message 'Value)

newtype SetNameArgs = SetNameArgs {name :: Text}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

newtype SendMessageArgs = SendMessageArgs {text :: Text}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

data App = App
  { user :: Table User
  , message :: Table Message
  , setName :: Reducer SetNameArgs
  , sendMessage :: Reducer SendMessageArgs
  , init :: LifecycleHook 'Init
  , clientConnected :: LifecycleHook 'OnConnect
  , clientDisconnected :: LifecycleHook 'OnDisconnect
  }
  deriving stock (Generic)

app :: App
app = deriveApp

data Handlers = Handlers
  { setName :: SetNameArgs -> ReducerM ()
  , sendMessage :: SendMessageArgs -> ReducerM ()
  , init :: () -> ReducerM ()
  , clientConnected :: () -> ReducerM ()
  , clientDisconnected :: () -> ReducerM ()
  }
  deriving stock (Generic)

-- | The derived chat module.
chatModule :: ModuleDef
chatModule =
  deriveModule
    app
    Handlers
      { setName = \_ -> pure () -- Task A4
      , sendMessage = \(SendMessageArgs t) -> do
          ReducerContext {sender = s, timestamp = ts} <- ask
          if T.null t
            then throwError "Messages must not be empty"
            else insertRow app.message (Message s ts t)
      , init = \() -> pure ()
      , clientConnected = \() -> pure () -- Task A5
      , clientDisconnected = \() -> pure () -- Task A5
      }
