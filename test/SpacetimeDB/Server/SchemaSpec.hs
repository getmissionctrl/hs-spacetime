{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Server.SchemaSpec (spec) where

import qualified Data.ByteString as BS
import SpacetimeDB.Server.Schema
import Test.Hspec

{- | The @event@ module described entirely in Haskell — the same shape as the
Rust @server/fixture-event@ whose @__describe_module__@ output was captured to
@phase1/golden/event.schema.bsatn@.
-}
eventModule :: ModuleSchema
eventModule =
  ModuleSchema
    { typespace = [TProduct [Field (Just "who") TString, Field (Just "at") TI64]]
    , types = [TypeDefSchema {scope = [], name = "Event", ref = 0, customOrdering = True}]
    , tables =
        [ TableSchema
            { name = "event"
            , productTypeRef = 0
            , tableType = UserTable
            , tableAccess = PublicTable
            , isEvent = False
            }
        ]
    , reducers =
        [ ReducerSchema {name = "delete_all", params = [], visibility = ClientCallable, okType = TProduct [], errType = TString}
        , ReducerSchema {name = "record", params = [Field (Just "note") TString], visibility = ClientCallable, okType = TProduct [], errType = TString}
        , ReducerSchema {name = "record_n", params = [Field (Just "count") TU32], visibility = ClientCallable, okType = TProduct [], errType = TString}
        ]
    }

{- | The @person@ module (phase0 fixture: table @person{name}@, reducer
@add(name)@) — a different, smaller shape, to prove the encoder generalizes.
-}
personModule :: ModuleSchema
personModule =
  ModuleSchema
    { typespace = [TProduct [Field (Just "name") TString]]
    , types = [TypeDefSchema {scope = [], name = "Person", ref = 0, customOrdering = True}]
    , tables =
        [ TableSchema
            { name = "person"
            , productTypeRef = 0
            , tableType = UserTable
            , tableAccess = PublicTable
            , isEvent = False
            }
        ]
    , reducers =
        [ReducerSchema {name = "add", params = [Field (Just "name") TString], visibility = ClientCallable, okType = TProduct [], errType = TString}]
    }

spec :: Spec
spec = describe "Server.Schema" $ do
  it "encodes the event module byte-identically to the captured Rust golden" $ do
    golden <- BS.readFile "phase1/golden/event.schema.bsatn"
    encodeModule eventModule `shouldBe` golden

  it "encodes the person module byte-identically to the captured Rust golden" $ do
    golden <- BS.readFile "phase0/golden/person.schema.bsatn"
    encodeModule personModule `shouldBe` golden
