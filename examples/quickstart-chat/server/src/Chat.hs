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
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Types (Identity, Timestamp)
import SpacetimeDB.Server (ModuleDef, deriveApp)
import SpacetimeDB.Server.HKD
  ( ColAttr (..)
  , Column
  , Lifecycle (..)
  , LifecycleHook
  , View (..)
  )
import SpacetimeDB.Server.Reducer (Reducer)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Table (Table)

data User f = User
  { identity :: Column f Identity '[ 'Pk]
  , name :: Column f (Maybe Text) '[]
  , online :: Column f Bool '[]
  }
  deriving stock (Generic)

deriving anyclass instance SpacetimeType (User 'Value)

data Message f = Message
  { sender :: Column f Identity '[]
  , sent :: Column f Timestamp '[]
  , text :: Column f Text '[]
  }
  deriving stock (Generic)

deriving anyclass instance SpacetimeType (Message 'Value)

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

-- | The derived chat module. Handlers wired in a later task.
chatModule :: ModuleDef
chatModule = error "not implemented"
