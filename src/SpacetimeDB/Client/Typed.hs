{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Typed client operations that consume the same 'Table' and 'Reducer' handles
and 'SpacetimeType' rows an author uses to define the server module — so one set
of Haskell types drives both ends, with no codegen and no stringly-typed reducer
names.

@
callTyped conn addWidget (AddWidgetArgs \"a\" 10) onReply     -- args checked, name from the handle
sub = subscribeTable widgetTable \"SELECT * FROM widget\" onRows  -- delivers decoded [Widget]
@
-}
module SpacetimeDB.Client.Typed
  ( callTyped
  , subscribeTable
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Client
import SpacetimeDB.Server.HKD (Row, View (..))
import SpacetimeDB.Server.Reducer (Reducer, reducerName)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Table (Table, tableName)

{- | Call a reducer through its typed handle: the name comes from the handle and
the argument is encoded via its 'SpacetimeType'. A mismatched argument type or
an undeclared handle is a compile error.
-}
callTyped
  :: (SpacetimeType args)
  => Client
  -> Reducer args
  -> args
  -> (ReplyPayload -> IO ())
  -> IO ()
callTyped c red args = callReducer c (reducerName red) (runEncoder encodeVal args)

{- | Subscribe to a table by its typed handle; the callback receives inserted and
deleted rows already decoded to @row@ via its 'SpacetimeType'. The query should
select from the same table (e.g. @"SELECT * FROM widget"@).
-}
subscribeTable
  :: forall (row :: Row)
   . (SpacetimeType (row 'Value))
  => Table row
  -> Text
  -> ([row 'Value] -> [row 'Value] -> IO ())
  -> Config
  -> Config
subscribeTable tbl query onRows =
  subscribeQuery (tableName tbl) query $ \case
    TypedInitial ins -> onRows (decodeRows ins) []
    TypedChange ins dels -> onRows (decodeRows ins) (decodeRows dels)
 where
  decodeRows :: [ByteString] -> [row 'Value]
  decodeRows = map decodeRow
  decodeRow bs = case runExact (decodeVal @(row 'Value)) bs of
    Right r -> r
    Left e -> error ("subscribeTable: row decode failed: " <> show e)
