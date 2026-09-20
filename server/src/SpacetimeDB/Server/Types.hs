module SpacetimeDB.Server.Types
  ( ModuleDef (..)
  , Reducer
  , reducer
  , ReducerContext (..)
  , ReducerM
  , TableId
  , ask
  , throwError
  , tableId
  , insert
  , scan
  , delete
  , logLine
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import SpacetimeDB.BSATN.Decoder (Decoder)
import SpacetimeDB.Server.Internal

-- | Build a reducer from an argument decoder and a handler.
reducer :: Decoder a -> (a -> ReducerM ()) -> Reducer
reducer = Reducer

ask :: ReducerM ReducerContext
ask = ReducerM $ \c _ -> pure (Right c)

throwError :: Text -> ReducerM a
throwError e = ReducerM $ \_ _ -> pure (Left e)

tableId :: Text -> ReducerM TableId
tableId n = backendOp (`beTableId` n)

insert :: TableId -> ByteString -> ReducerM ()
insert t row = backendOp (\b -> beInsert b t row)

scan :: TableId -> ReducerM [ByteString]
scan t = backendOp (`beScan` t)

delete :: TableId -> ByteString -> ReducerM ()
delete t row = backendOp (\b -> beDelete b t row)

logLine :: Text -> ReducerM ()
logLine msg = backendOp (\b -> Right <$> beLog b msg)
