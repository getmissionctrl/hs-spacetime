module SpacetimeDB.Client.State
  ( ClientState (..)
  , LiveSub (..)
  , emptyState
  , allocateCall, takePending, drainPending
  , allocateSub, forgetSub, subForId
  , learnToken
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Word (Word32)

data LiveSub = LiveSub
  { subQuerySetId :: Word32
  , subQuery :: Text
  , subTable :: Maybe Text -- typed subscriptions carry a table name
  }
  deriving (Eq, Show)

data ClientState = ClientState
  { token :: Maybe Text
  , subscriptions :: [LiveSub]
  , nextQuerySetId :: Word32
  , pendingCalls :: Map Int Text -- request_id -> call name
  , nextRequestId :: Int
  }
  deriving (Eq, Show)

emptyState :: ClientState
emptyState = ClientState Nothing [] 1 M.empty 1

allocateCall :: ClientState -> Text -> (ClientState, Int)
allocateCall s name =
  let rid = nextRequestId s
   in ( s
          { nextRequestId = rid + 1
          , pendingCalls = M.insert rid name (pendingCalls s)
          }
      , rid
      )

takePending :: ClientState -> Int -> (ClientState, Maybe Text)
takePending s rid = case M.lookup rid (pendingCalls s) of
  Nothing -> (s, Nothing)
  Just nm -> (s {pendingCalls = M.delete rid (pendingCalls s)}, Just nm)

drainPending :: ClientState -> (ClientState, [(Int, Text)])
drainPending s = (s {pendingCalls = M.empty}, M.toList (pendingCalls s))

-- | Allocate a new subscription id (monotonic, never reused).
allocateSub :: ClientState -> Text -> Maybe Text -> (ClientState, LiveSub)
allocateSub s query tbl =
  let qsid = nextQuerySetId s
      sub = LiveSub qsid query tbl
   in (s {nextQuerySetId = qsid + 1, subscriptions = subscriptions s ++ [sub]}, sub)

forgetSub :: ClientState -> Word32 -> ClientState
forgetSub s qsid = s {subscriptions = filter ((/= qsid) . subQuerySetId) (subscriptions s)}

subForId :: ClientState -> Word32 -> Maybe LiveSub
subForId s qsid = case filter ((== qsid) . subQuerySetId) (subscriptions s) of
  (x : _) -> Just x
  [] -> Nothing

learnToken :: ClientState -> Text -> ClientState
learnToken s t = s {token = Just t}
