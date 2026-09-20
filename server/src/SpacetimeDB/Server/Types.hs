{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

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
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import SpacetimeDB.BSATN.Decoder (Decoder, runDecoder)
import SpacetimeDB.Server.Internal

-- | Build a reducer from an argument decoder and a handler.
reducer :: Decoder a -> (a -> ReducerM ()) -> Reducer
reducer = Reducer

ask :: ReducerM ReducerContext
ask = ReducerM $ \c _ -> pure (Right c)

throwError :: Text -> ReducerM a
throwError e = ReducerM $ \_ _ -> pure (Left e)

tableId :: Text -> ReducerM TableId
tableId n = backendOp (\b -> b.tableId n)

insert :: TableId -> ByteString -> ReducerM ()
insert t row = backendOp (\b -> b.insert t row)

{- | Scan a table into its individual rows' raw BSATN bytes. The host returns one
concatenated batch of BSATN-encoded rows; the given row decoder is used only to
find each row's boundary so the exact per-row bytes can be recovered (e.g. to
feed 'delete'). The decoded value itself is discarded.
-}
scan :: Decoder a -> TableId -> ReducerM [ByteString]
scan dec t = do
  batch <- backendOp (\b -> b.scan t)
  either throwError pure (splitRows dec batch)

{- | Split a concatenated BSATN row batch into per-row byte slices by repeatedly
decoding one row and measuring how many bytes it consumed.
-}
splitRows :: Decoder a -> ByteString -> Either Text [ByteString]
splitRows dec = go
 where
  go bs
    | BS.null bs = Right []
    | otherwise = case runDecoder dec bs of
        Left err -> Left ("row decode failed: " <> T.pack (show err))
        Right (_, rest)
          | BS.length rest >= BS.length bs -> Left "row decoder consumed no bytes"
          | otherwise ->
              let row = BS.take (BS.length bs - BS.length rest) bs
               in (row :) <$> go rest

delete :: TableId -> ByteString -> ReducerM ()
delete t row = backendOp (\b -> b.delete t row)

logLine :: Text -> ReducerM ()
logLine msg = backendOp (\b -> Right <$> b.log msg)
