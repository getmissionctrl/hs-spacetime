{-# LANGUAGE OverloadedStrings #-}

{- | Spawn @scripts/live-harness.sh serve@ as a child, parse its @READY@ line,
and tear it down (by closing its stdin) when the body returns. Used only by
the opt-in live suite.
-}
module SpacetimeDB.Live.Harness
  ( withLiveServer
  , waitUntil
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket)
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (BufferMode (..), Handle, hClose, hGetLine, hSetBuffering)
import System.Process

-- | Run @body port database@ against a freshly-booted throwaway server.
withLiveServer :: (Int -> Text -> IO a) -> IO a
withLiveServer body =
  bracket start cleanup $ \(hin, hout, ph) -> do
    (port, db) <- readReady hout
    r <- body port db
    hClose hin -- EOF tells the harness to tear down
    _ <- waitForProcess ph
    pure r
 where
  start = do
    (Just hin, Just hout, _, ph) <-
      createProcess
        (proc "bash" ["scripts/live-harness.sh", "serve"])
          { std_in = CreatePipe
          , std_out = CreatePipe
          }
    hSetBuffering hin LineBuffering
    pure (hin, hout, ph)
  cleanup (hin, _, ph) = do
    hClose hin
    _ <- waitForProcess ph
    pure ()

readReady :: Handle -> IO (Int, Text)
readReady h = go
 where
  go = do
    line <- hGetLine' h
    case T.words (T.pack line) of
      ("READY" : p : d : _) -> pure (read (T.unpack p), d)
      _ -> go

-- hGetLine that fails clearly at EOF instead of hanging.
hGetLine' :: Handle -> IO String
hGetLine' = hGetLine

{- | Poll @predicate@ against an accumulating event log until it holds or the
timeout (in ms) elapses.
-}
waitUntil :: TVar [a] -> ([a] -> Bool) -> Int -> IO Bool
waitUntil var predy timeoutMs = go (timeoutMs `div` 20)
 where
  go n
    | n <= 0 = predy <$> readTVarIO var
    | otherwise = do
        ok <- predy <$> readTVarIO var
        if ok
          then pure True
          else threadDelay 20000 >> go (n - 1)
