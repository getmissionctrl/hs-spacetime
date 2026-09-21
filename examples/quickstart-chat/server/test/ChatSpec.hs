{-# LANGUAGE LambdaCase #-}

{- | Chat module scaffolding test.

Asserts that 'chatModule' declares the @user@ and @message@ tables. The module
exposes only its encoded @RawModuleDef::V10@ 'schemaBytes' (no 'ModuleSchema'
accessor), so this test decodes the table names straight out of those bytes
with a small V10 reader that mirrors "SpacetimeDB.Server.Schema"'s encoder.
-}
module ChatSpec (spec) where

import Data.Text (Text)
import SpacetimeDB.BSATN.Decoder
  ( DecodeError (UnknownVariant)
  , Decoder
  , bool
  , i128
  , list
  , optional
  , runExact
  , string
  , sumD
  , u16
  , u32
  , u8
  )
import SpacetimeDB.Server.Internal (ModuleDef (..))
import Test.Hspec

import Chat (chatModule)

spec :: Spec
spec =
  describe "Chat.chatModule" $
    it "declares the user and message tables" $ do
      let names = moduleTableNames chatModule
      names `shouldContain` ["user"]
      names `shouldContain` ["message"]

-- | Extract the declared table names from a module's encoded V10 schema.
moduleTableNames :: ModuleDef -> [Text]
moduleTableNames m =
  case runExact moduleSections m.schemaBytes of
    Left e -> error ("failed to decode module schema bytes: " <> show e)
    Right sections -> concat [ns | TablesSection ns <- sections]

{- | The sections we care to distinguish; every other section is decoded and
discarded so the byte cursor advances to the Tables section.
-}
data Section = TablesSection [Text] | OtherSection

-- | @RawModuleDef@ is a versioned sum; V10 is tag 2 wrapping a @Vec\<Section>@.
moduleSections :: Decoder [Section]
moduleSections = sumD $ \case
  2 -> Right (list sectionD)
  t -> Left (UnknownVariant t)

-- | A single V10 section, keyed by the same sum tags the encoder emits.
sectionD :: Decoder Section
sectionD = sumD $ \case
  0 -> Right (list algTypeD >> pure OtherSection) -- Typespace
  1 -> Right (list typeDefD >> pure OtherSection) -- Types
  2 -> Right (TablesSection <$> list tableD) -- Tables
  3 -> Right (list reducerD >> pure OtherSection) -- Reducers
  7 -> Right (list lifecycleEntryD >> pure OtherSection) -- LifeCycleReducers
  10 -> Right (u32 >> pure OtherSection) -- ExplicitNames { entries: [] }
  t -> Left (UnknownVariant t)

-- | Decode a table, returning its name (the only field this test needs).
tableD :: Decoder Text
tableD = do
  name <- string
  _productTypeRef <- u32
  _primaryKey <- list u16
  _indexes <- list indexD
  _constraints <- list constraintD
  _sequences <- list sequenceD
  _tableType <- u8
  _tableAccess <- u8
  _defaultValues <- u32
  _isEvent <- bool
  pure name

indexD :: Decoder ()
indexD = do
  _sourceName <- optional string
  _accessorName <- optional string
  _algorithm <- sumD $ \case
    0 -> Right (list u16 >> pure ()) -- BTree
    t -> Left (UnknownVariant t)
  pure ()

constraintD :: Decoder ()
constraintD = do
  _sourceName <- optional string
  _data <- sumD $ \case
    0 -> Right (list u16 >> pure ()) -- Unique
    t -> Left (UnknownVariant t)
  pure ()

sequenceD :: Decoder ()
sequenceD = do
  _sourceName <- optional string
  _column <- u16
  _start <- optional i128
  _minValue <- optional i128
  _maxValue <- optional i128
  _increment <- i128
  pure ()

typeDefD :: Decoder ()
typeDefD = do
  _scope <- list string
  _name <- string
  _ref <- u32
  _customOrdering <- bool
  pure ()

reducerD :: Decoder ()
reducerD = do
  _name <- string
  _params <- list fieldD
  _visibility <- u8
  _okReturn <- algTypeD
  _errReturn <- algTypeD
  pure ()

lifecycleEntryD :: Decoder ()
lifecycleEntryD = do
  _tag <- u8
  _name <- string
  pure ()

fieldD :: Decoder ()
fieldD = do
  _name <- optional string
  _ty <- algTypeD
  pure ()

-- | Decode (and discard) an 'AlgType'; primitives carry no payload.
algTypeD :: Decoder ()
algTypeD = sumD $ \case
  0 -> Right (u32 >> pure ()) -- Ref
  1 -> Right (list fieldD >> pure ()) -- Sum
  2 -> Right (list fieldD >> pure ()) -- Product
  3 -> Right algTypeD -- Array
  t
    | t >= 4 && t <= 19 -> Right (pure ()) -- String/Bool/I8..F64
    | otherwise -> Left (UnknownVariant t)
