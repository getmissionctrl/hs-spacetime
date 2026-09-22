module Main (main) where

import Chat.Tui.ModelSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec Chat.Tui.ModelSpec.spec
