{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

module SpacetimeDB.Server.Internal where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Generics (Generic)
import SpacetimeDB.BSATN.Decoder (Decoder)
import SpacetimeDB.BSATN.Types (ConnectionId, Identity, Timestamp)

newtype TableId = TableId Word32
  deriving stock (Eq, Show, Generic)

-- | Decoded reducer invocation context (pure data).
data ReducerContext = ReducerContext
  { sender :: !Identity
  , connectionId :: !(Maybe ConnectionId)
  , timestamp :: !Timestamp
  }
  deriving stock (Show, Eq, Generic)

{- | The host-effect capability set. Native tests inject a fake; the wasm ABI
module injects one backed by FFI. Each op reports failure as 'Left' errno text.
Fields are plain (no prefixes); access via record-dot, e.g. @backend.insert@.
-}
data Backend = Backend
  { tableId :: !(Text -> IO (Either Text TableId))
  , insert :: !(TableId -> ByteString -> IO (Either Text ()))
  , scan :: !(TableId -> IO (Either Text ByteString))
  {- ^ Scan a table, returning the host's raw concatenated BSATN row batch. The
  runtime 'scan' primitive splits it into per-row byte slices using a decoder,
  since row boundaries are only knowable from the table's row type.
  -}
  , delete :: !(TableId -> ByteString -> IO (Either Text ()))
  , log :: !(Text -> IO ())
  }
  deriving stock (Generic)

{- | Restricted reducer monad: IO at the base, but no MonadIO is exported, so a
reducer can only perform effects through the primitives below.
-}
newtype ReducerM a = ReducerM {unReducerM :: ReducerContext -> Backend -> IO (Either Text a)}

instance Functor ReducerM where
  fmap f (ReducerM g) = ReducerM $ \c b -> fmap (fmap f) (g c b)

instance Applicative ReducerM where
  pure x = ReducerM $ \_ _ -> pure (Right x)
  ReducerM gf <*> ReducerM gx = ReducerM $ \c b -> do
    ef <- gf c b
    case ef of
      Left e -> pure (Left e)
      Right f -> fmap (fmap f) (gx c b)

instance Monad ReducerM where
  ReducerM g >>= k = ReducerM $ \c b -> do
    ex <- g c b
    case ex of
      Left e -> pure (Left e)
      Right x -> (k x).unReducerM c b

-- | Internal bridge from a backend op into ReducerM. NOT re-exported publicly.
backendOp :: (Backend -> IO (Either Text a)) -> ReducerM a
backendOp f = ReducerM $ \_ b -> f b

data Reducer = forall a. Reducer (Decoder a) (a -> ReducerM ())

data ModuleDef = ModuleDef
  { schemaBytes :: !ByteString
  , reducers :: ![Reducer]
  }
  deriving stock (Generic)
