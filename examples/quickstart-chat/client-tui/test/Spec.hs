module Main (main) where

import qualified Chat.Tui.ModelSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec Chat.Tui.ModelSpec.spec
