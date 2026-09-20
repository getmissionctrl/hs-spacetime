{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Typed table handles and row operations. A @Table row@ names a table whose
rows are a @SpacetimeType@; the operations encode/decode rows automatically, so a
reducer never touches raw BSATN:

@
eventTable :: Table Event
eventTable = table \"event\"

record note = insertRow eventTable (Event note ...)
@

These sit on top of the raw 'SpacetimeDB.Server.Types' primitives.
-}
module SpacetimeDB.Server.Table
  ( Table
  , table
  , tableName
  , insertRow
  , deleteRow
  , scanRows
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Types

-- | A typed handle to a table whose rows are @row@. Phantom in @row@.
newtype Table row = Table Text

-- | Name a table.
table :: Text -> Table row
table = Table

-- | The table's name.
tableName :: Table row -> Text
tableName (Table n) = n

-- | Insert a typed row (encoded to BSATN via its 'SpacetimeType').
insertRow :: (SpacetimeType row) => Table row -> row -> ReducerM ()
insertRow (Table n) row = do
  t <- tableId n
  insert t (runEncoder encodeVal row)

-- | Delete rows equal to the given typed row.
deleteRow :: (SpacetimeType row) => Table row -> row -> ReducerM ()
deleteRow (Table n) row = do
  t <- tableId n
  delete t (runEncoder encodeVal row)

-- | Scan the whole table, decoding each row to @row@.
scanRows :: forall row. (SpacetimeType row) => Table row -> ReducerM [row]
scanRows (Table n) = do
  t <- tableId n
  raws <- scan (decodeVal @row) t
  traverse decodeRow raws
 where
  decodeRow bs = case runExact (decodeVal @row) bs of
    Right r -> pure r
    Left e -> throwError ("row decode failed: " <> T.pack (show e))
