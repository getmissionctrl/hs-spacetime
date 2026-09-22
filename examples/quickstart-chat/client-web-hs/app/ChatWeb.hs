{-# LANGUAGE ForeignFunctionInterface #-}

module ChatWeb (main) where

import Chat.Web.Ffi (hs_on_frame, hs_send_message, hs_set_name, hs_subscribe)
import GHC.Wasm.Prim

foreign export javascript "hs_subscribe" hs_subscribe :: IO JSVal
foreign export javascript "hs_on_frame" hs_on_frame :: JSVal -> IO JSString
foreign export javascript "hs_send_message" hs_send_message :: JSString -> IO JSVal
foreign export javascript "hs_set_name" hs_set_name :: JSString -> IO JSVal

main :: IO ()
main = pure ()
