module Main (main) where

import Test.Hspec (hspec, describe, it, shouldBe)

main :: IO ()
main = hspec $ describe "bootstrap" $ it "runs" $ (1 :: Int) `shouldBe` 1
