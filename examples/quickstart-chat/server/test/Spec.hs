module Main (main) where

import ChatSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec ChatSpec.spec
