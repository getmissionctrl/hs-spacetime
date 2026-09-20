{-# LANGUAGE ExistentialQuantification #-}
module SpacetimeDB.Server.Internal where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word32)
import SpacetimeDB.BSATN.Decoder (Decoder)
import SpacetimeDB.BSATN.Types (ConnectionId, Identity, Timestamp)

newtype TableId = TableId Word32 deriving (Eq, Show)

-- | Decoded reducer invocation context (pure data).
data ReducerContext = ReducerContext
  { sender       :: Identity
  , connectionId :: Maybe ConnectionId
  , timestamp    :: Timestamp
  }

-- | The host-effect capability set. Native tests inject a fake; the wasm ABI
-- module injects one backed by FFI. Each op reports failure as 'Left' errno text.
data Backend = Backend
  { beTableId :: Text -> IO (Either Text TableId)
  , beInsert  :: TableId -> ByteString -> IO (Either Text ())
  , beScan    :: TableId -> IO (Either Text [ByteString])
  , beDelete  :: TableId -> ByteString -> IO (Either Text ())
  , beLog     :: Text -> IO ()
  }

-- | Restricted reducer monad: IO at the base, but no MonadIO is exported, so a
-- reducer can only perform effects through the primitives below.
newtype ReducerM a = ReducerM { unReducerM :: ReducerContext -> Backend -> IO (Either Text a) }

instance Functor ReducerM where
  fmap f (ReducerM g) = ReducerM $ \c b -> fmap (fmap f) (g c b)

instance Applicative ReducerM where
  pure x = ReducerM $ \_ _ -> pure (Right x)
  ReducerM gf <*> ReducerM gx = ReducerM $ \c b -> do
    ef <- gf c b
    case ef of
      Left e  -> pure (Left e)
      Right f -> fmap (fmap f) (gx c b)

instance Monad ReducerM where
  ReducerM g >>= k = ReducerM $ \c b -> do
    ex <- g c b
    case ex of
      Left e  -> pure (Left e)
      Right x -> unReducerM (k x) c b

-- | Internal bridge from a backend op into ReducerM. NOT re-exported publicly.
backendOp :: (Backend -> IO (Either Text a)) -> ReducerM a
backendOp f = ReducerM $ \_ b -> f b

data Reducer = forall a. Reducer (Decoder a) (a -> ReducerM ())

data ModuleDef = ModuleDef
  { schemaBytes :: ByteString
  , reducers    :: [Reducer]
  }
