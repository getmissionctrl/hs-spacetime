module Main (main) where

import qualified Chat.Web.CoreSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec Chat.Web.CoreSpec.spec
