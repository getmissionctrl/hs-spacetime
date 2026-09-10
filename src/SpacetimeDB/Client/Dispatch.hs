module SpacetimeDB.Client.Dispatch
  ( DispatchAction (..)
  , RawOp (..)
  , routeTableUpdate
  , routeInitial
  ) where

import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text (Text)
import SpacetimeDB.Client.State (LiveSub (..))
import SpacetimeDB.Protocol.Messages

data RawOp = Initial' Text [ByteString] | Changed' Text [ByteString] [ByteString]
  deriving (Eq, Show)

data DispatchAction
  = ToTyped Text Text [ByteString] [ByteString] -- table, query, inserts, deletes
  | ToRaw RawOp
  deriving (Eq, Show)

-- newest typed sub wins for a given table
typedSubFor :: [LiveSub] -> Text -> Maybe LiveSub
typedSubFor subs tbl =
  find (\s -> subTable s == Just tbl) (reverse subs)

routeTableUpdate :: [LiveSub] -> TableUpdate -> [DispatchAction]
routeTableUpdate subs (TableUpdate tbl rowsList) =
  concatMap (opFor tbl) rowsList
 where
  opFor t (PersistentTable ins del) = emit t ins del
  opFor t (EventTable evs) = emit t evs []
  emit t ins del
    | null ins && null del = []
    | otherwise = case typedSubFor subs t of
        Just s -> [ToTyped t (subQuery s) ins del]
        Nothing -> [ToRaw (Changed' t ins del)]

routeInitial :: [LiveSub] -> SingleTableRows -> [DispatchAction]
routeInitial subs (SingleTableRows tbl rows) =
  case typedSubFor subs tbl of
    Just s -> [ToTyped tbl (subQuery s) rows []]
    Nothing -> [ToRaw (Initial' tbl rows)]
