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
import SpacetimeDB.Server (ModuleDef, ask, deleteRow, deriveApp, insertRow, scanRows, throwError)
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

userIdentity :: User 'Value -> Identity
userIdentity (User i _ _) = i

-- | Apply @present@ to the sender's user row if one exists, else run @absent@.
withSenderUser :: (User 'Value -> ReducerM ()) -> ReducerM () -> ReducerM ()
withSenderUser present absent = do
  ReducerContext {sender = s} <- ask
  users <- scanRows app.user
  case filter (\u -> userIdentity u == s) users of
    (u : _) -> present u
    [] -> absent

setOnline :: Bool -> ReducerM ()
setOnline flag = do
  ReducerContext {sender = s} <- ask
  withSenderUser
    (\old@(User i n _) -> deleteRow app.user old >> insertRow app.user (User i n flag))
    (if flag then insertRow app.user (User s Nothing True) else pure ())

-- | The derived chat module.
chatModule :: ModuleDef
chatModule =
  deriveModule
    app
    Handlers
      { setName = \(SetNameArgs n) ->
          if T.null n
            then throwError "Names must not be empty"
            else
              withSenderUser
                (\old@(User i _ o) -> deleteRow app.user old >> insertRow app.user (User i (Just n) o))
                (throwError "Cannot set name for unknown user")
      , sendMessage = \(SendMessageArgs t) -> do
          ReducerContext {sender = s, timestamp = ts} <- ask
          if T.null t
            then throwError "Messages must not be empty"
            else insertRow app.message (Message s ts t)
      , init = \() -> pure ()
      , clientConnected = \() -> setOnline True
      , clientDisconnected = \() -> setOnline False
      }
