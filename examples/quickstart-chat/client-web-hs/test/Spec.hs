module Main (main) where

import Chat.Web.CoreSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec Chat.Web.CoreSpec.spec
