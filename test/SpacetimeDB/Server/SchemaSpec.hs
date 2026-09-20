{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module SpacetimeDB.Server.SchemaSpec (spec) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import SpacetimeDB.Server.Schema
import Test.Hspec

-- | A plain table with no primary key / indexes / constraints / sequences.
plainTable :: Text -> TableSchema
plainTable n =
  TableSchema
    { name = n
    , productTypeRef = 0
    , primaryKey = []
    , indexes = []
    , constraints = []
    , sequences = []
    , tableType = UserTable
    , tableAccess = PublicTable
    , isEvent = False
    }

callable :: Text -> [Field] -> ReducerSchema
callable n ps = ReducerSchema {name = n, params = ps, lifecycle = Nothing}

-- The @event@ module (phase1 fixture).
eventModule :: ModuleSchema
eventModule =
  ModuleSchema
    { typespace = [TProduct [Field (Just "who") TString, Field (Just "at") TI64]]
    , types = [TypeDefSchema {scope = [], name = "Event", ref = 0, customOrdering = True}]
    , tables = [plainTable "event"]
    , reducers =
        [ callable "delete_all" []
        , callable "record" [Field (Just "note") TString]
        , callable "record_n" [Field (Just "count") TU32]
        ]
    }

-- The @person@ module (phase0 fixture) — a different, smaller shape.
personModule :: ModuleSchema
personModule =
  ModuleSchema
    { typespace = [TProduct [Field (Just "name") TString]]
    , types = [TypeDefSchema {scope = [], name = "Person", ref = 0, customOrdering = True}]
    , tables = [plainTable "person"]
    , reducers = [callable "add" [Field (Just "name") TString]]
    }

-- The @widget@ module (fixture/): primary key + auto-inc on @id@, an @init@
-- lifecycle reducer, and @add_widget@.
widgetModule :: ModuleSchema
widgetModule =
  ModuleSchema
    { typespace =
        [ TProduct
            [ Field (Just "id") TU64
            , Field (Just "name") TString
            , Field (Just "quantity") TU32
            ]
        ]
    , types = [TypeDefSchema {scope = [], name = "Widget", ref = 0, customOrdering = True}]
    , tables =
        [ TableSchema
            { name = "widget"
            , productTypeRef = 0
            , primaryKey = [0]
            , indexes =
                [ IndexDef
                    { sourceName = Just "widget_id_idx_btree"
                    , accessorName = Just "id"
                    , columns = [0]
                    }
                ]
            , constraints = [ConstraintDef {sourceName = Nothing, uniqueColumns = [0]}]
            , sequences =
                [ SequenceDef
                    { sourceName = Nothing
                    , column = 0
                    , start = Nothing
                    , minValue = Nothing
                    , maxValue = Nothing
                    , increment = 1
                    }
                ]
            , tableType = UserTable
            , tableAccess = PublicTable
            , isEvent = False
            }
        ]
    , reducers =
        [ callable "add_widget" [Field (Just "name") TString, Field (Just "quantity") TU32]
        , ReducerSchema {name = "init", params = [], lifecycle = Just Init}
        ]
    }

spec :: Spec
spec = describe "Server.Schema" $ do
  it "encodes the event module byte-identically to the captured Rust golden" $ do
    golden <- BS.readFile "phase1/golden/event.schema.bsatn"
    encodeModule eventModule `shouldBe` golden

  it "encodes the person module byte-identically to the captured Rust golden" $ do
    golden <- BS.readFile "phase0/golden/person.schema.bsatn"
    encodeModule personModule `shouldBe` golden

  it "encodes the widget module (PK/auto-inc/lifecycle) byte-identically to the golden" $ do
    golden <- BS.readFile "phase2/golden/widget.schema.bsatn"
    encodeModule widgetModule `shouldBe` golden
