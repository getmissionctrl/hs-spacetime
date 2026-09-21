{-# LANGUAGE ForeignFunctionInterface #-}

module Spike (main) where

import GHC.Wasm.Prim

foreign import javascript "((s) => { document.getElementById('log').innerText += s + '\\n'; })"
  js_log :: JSString -> IO ()

foreign import javascript "((url) => new WebSocket(url))"
  js_wsOpen :: JSString -> IO JSVal

foreign import javascript "wrapper"
  wrapCb :: IO () -> IO JSVal

foreign import javascript "((ws, cb) => { ws.onopen = cb; })"
  js_onOpen :: JSVal -> JSVal -> IO ()

-- | Called from JS after the page loads.
startSpike :: JSString -> IO ()
startSpike url = do
  js_log (toJSString "haskell: opening socket")
  ws <- js_wsOpen url
  cb <- wrapCb (js_log (toJSString "haskell: socket open callback fired"))
  js_onOpen ws cb

foreign export javascript "startSpike" startSpike :: JSString -> IO ()

main :: IO ()
main = pure ()
