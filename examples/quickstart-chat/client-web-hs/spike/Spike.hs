{-# LANGUAGE ForeignFunctionInterface #-}

module Spike (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import GHC.Wasm.Prim
import System.IO (hFlush, stdout)

foreign import javascript "((url) => new WebSocket(url))"
  js_wsOpen :: JSString -> IO JSVal

foreign import javascript "wrapper"
  wrapCb :: IO () -> IO JSVal

foreign import javascript "((ws, cb) => { ws.onopen = cb; })"
  js_onOpen :: JSVal -> JSVal -> IO ()

foreign import javascript "((ws, cb) => { ws.onerror = cb; ws.onclose = cb; })"
  js_onErrClose :: JSVal -> JSVal -> IO ()

foreign import javascript "((cb, ms) => { setTimeout(cb, ms); })"
  js_setTimeout :: JSVal -> Int -> IO ()

-- Log via WASI stdout (the host page pipes fd 1 to the on-page log), which
-- avoids any JSString->DOM marshalling questions.
say :: String -> IO ()
say s = putStrLn s >> hFlush stdout

-- | Called from JS after the page loads. Opens a WebSocket and installs Haskell
-- closures as its onopen / onerror / onclose handlers.
startSpike :: JSString -> IO ()
startSpike url = do
  say "haskell: opening socket"
  ws <- js_wsOpen url
  openCb <- wrapCb (say "haskell: socket OPEN callback fired")
  js_onOpen ws openCb
  errCb <- wrapCb (say "haskell: socket ERROR/CLOSE callback fired")
  js_onErrClose ws errCb
  -- Network-independent proof that a Haskell wrapper-callback fires AFTER the
  -- async export has returned: schedule one via setTimeout(500ms).
  timerCb <- wrapCb (say "haskell: TIMER callback fired (wrapper callbacks work)")
  js_setTimeout timerCb 500
  say "haskell: startSpike body complete; keeping RTS alive"
  -- Keep a Haskell thread alive so the RTS keeps servicing JS callbacks
  -- (the WebSocket handlers + the setTimeout). Without this the exported
  -- action returns, the RTS goes idle, and later callbacks never run.
  forever (threadDelay 3600000000)

foreign export javascript "startSpike" startSpike :: JSString -> IO ()

main :: IO ()
main = pure ()
