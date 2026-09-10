{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Codegen.SchemaSpec (spec) where

import qualified Data.ByteString.Lazy as BL
import Data.List (find)
import SpacetimeDB.Codegen.Schema
import Test.Hspec

spec :: Spec
spec =
  it "parses tables/reducers, resolves a ref to a product, and names the type" $ do
    raw <- BL.readFile "test/fixtures/sample.schema.json"
    case parseModule raw of
      Left e -> expectationFailure e
      Right m0 -> do
        let m = computeNamedDropped m0
        map tblName (modTables m) `shouldBe` ["widget"]
        map redName (modReducers m) `shouldBe` ["add_widget", "init"]
        case find ((== "add_widget") . redName) (modReducers m) of
          Just r -> map fieldName (redParams r) `shouldBe` [Just "name", Just "quantity"]
          Nothing -> expectationFailure "add_widget not found"
        case resolve m (TRef 0) of
          Right (TProduct fs) -> length fs `shouldBe` 3
          other -> expectationFailure ("expected product, got " ++ show other)
        modNamed m `shouldBe` [0]
