{-# LANGUAGE OverloadedStrings #-}

{- | Model and parser for the @RawModuleDefV10@ schema emitted by
@spacetime describe --json@. The JSON is SATS-serde: sums and
@AlgebraicType@s are single-key tagged objects (@{"Product": …}@,
@{"U64": []}@), options are @{"some": x}@ / @{"none": []}@, and refs are
typespace indices.
-}
module SpacetimeDB.Codegen.Schema
  ( Typ (..)
  , Field (..)
  , Visibility (..)
  , TypeDef (..)
  , TableDef (..)
  , Reducer (..)
  , Procedure (..)
  , Module (..)
  , parseModule
  , resolve
  , renderable
  , computeNamedDropped
  ) where

import Data.Aeson (Value (..), eitherDecode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, parseEither, typeMismatch)
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

-- | A structural type. @TRef@ indexes the typespace.
data Typ
  = TRef Int
  | TSum [Field]
  | TProduct [Field]
  | TArray Typ
  | TPrim Text
  deriving (Eq, Show)

-- | A named-or-anonymous element of a product/sum/parameter list.
data Field = Field
  { fieldName :: Maybe Text
  , fieldTy :: Typ
  }
  deriving (Eq, Show)

data Visibility = ClientCallable | Private
  deriving (Eq, Show)

-- | A declared, exported type: a name plus the typespace ref holding its body.
data TypeDef = TypeDef
  { tdName :: Text
  , tdRef :: Int
  }
  deriving (Eq, Show)

data TableDef = TableDef
  { tblName :: Text
  , tblProductRef :: Int
  }
  deriving (Eq, Show)

data Reducer = Reducer
  { redName :: Text
  , redParams :: [Field]
  , redVisibility :: Visibility
  , redOk :: Typ
  , redErr :: Typ
  }
  deriving (Eq, Show)

data Procedure = Procedure
  { procName :: Text
  , procParams :: [Field]
  , procVisibility :: Visibility
  , procReturn :: Typ
  }
  deriving (Eq, Show)

data Module = Module
  { modTypespace :: [Typ]
  , modTypes :: [TypeDef]
  , modTables :: [TableDef]
  , modReducers :: [Reducer]
  , modProcedures :: [Procedure]
  , modCanonical :: Map Text Text
  -- ^ function source_name -> canonical_name
  , modNamed :: [Int]
  -- ^ typespace refs that become named Haskell types (computed)
  , modDropped :: Map Int Text
  -- ^ typespace ref -> reason it was dropped (computed)
  }
  deriving (Eq, Show)

-- Parsing ------------------------------------------------------------------

parseModule :: BL.ByteString -> Either String Module
parseModule bs = eitherDecode bs >>= parseEither moduleP

-- | A single-key tagged object: return (tag, payload).
tagged :: Value -> Parser (Text, Value)
tagged (Object o) = case KM.toList o of
  [(k, v)] -> pure (Key.toText k, v)
  _ -> fail ("expected a single-key tagged object, got keys: " ++ show (map fst (KM.toList o)))
tagged v = typeMismatch "tagged object" v

field :: Text -> Value -> Parser Value
field k (Object o) = maybe (fail ("missing key " ++ show k)) pure (KM.lookup (Key.fromText k) o)
field k v = typeMismatch ("object with key " ++ show k) v

array :: Value -> Parser [Value]
array (Array a) = pure (V.toList a)
array v = typeMismatch "array" v

text :: Value -> Parser Text
text (String t) = pure t
text v = typeMismatch "string" v

intOf :: Value -> Parser Int
intOf (Number n) = maybe (fail "non-integral number") pure (toBoundedInteger n)
intOf v = typeMismatch "integer" v

-- | @{"some": x}@ -> Just x; @{"none": []}@ -> Nothing.
optionP :: (Value -> Parser a) -> Value -> Parser (Maybe a)
optionP p v = do
  (tag, payload) <- tagged v
  case tag of
    "some" -> Just <$> p payload
    "none" -> pure Nothing
    other -> fail ("bad option tag " ++ show other)

algP :: Value -> Parser Typ
algP v = do
  (tag, payload) <- tagged v
  case tag of
    "Ref" -> TRef <$> intOf payload
    "Sum" -> TSum <$> (field "variants" payload >>= array >>= mapM fieldP)
    "Product" -> TProduct <$> (field "elements" payload >>= array >>= mapM fieldP)
    "Array" -> TArray <$> (field "elem_ty" payload >>= algP)
    prim -> pure (TPrim prim)

fieldP :: Value -> Parser Field
fieldP v = do
  nm <- field "name" v >>= optionP text
  ty <- field "algebraic_type" v >>= algP
  pure (Field nm ty)

productElemsP :: Value -> Parser [Field]
productElemsP v = field "elements" v >>= array >>= mapM fieldP

visibilityP :: Value -> Parser Visibility
visibilityP v = do
  (tag, _) <- tagged v
  case tag of
    "ClientCallable" -> pure ClientCallable
    "Private" -> pure Private
    other -> fail ("unknown visibility " ++ show other)

typeDefP :: Value -> Parser TypeDef
typeDefP v = do
  nm <- field "source_name" v >>= field "source_name" >>= text
  r <- field "ty" v >>= intOf
  pure (TypeDef nm r)

tableP :: Value -> Parser TableDef
tableP v = TableDef <$> (field "source_name" v >>= text) <*> (field "product_type_ref" v >>= intOf)

reducerP :: Value -> Parser Reducer
reducerP v =
  Reducer
    <$> (field "source_name" v >>= text)
    <*> (field "params" v >>= productElemsP)
    <*> (field "visibility" v >>= visibilityP)
    <*> (field "ok_return_type" v >>= algP)
    <*> (field "err_return_type" v >>= algP)

procedureP :: Value -> Parser Procedure
procedureP v =
  Procedure
    <$> (field "source_name" v >>= text)
    <*> (field "params" v >>= productElemsP)
    <*> (field "visibility" v >>= visibilityP)
    <*> (field "return_type" v >>= algP)

explicitNamesP :: Value -> Parser (Map Text Text)
explicitNamesP v = do
  entries <- field "entries" v >>= array
  pairs <- mapM entryP entries
  pure (M.fromList (concat pairs))
 where
  entryP e = do
    (tag, payload) <- tagged e
    case tag of
      "Function" -> do
        s <- field "source_name" payload >>= text
        c <- field "canonical_name" payload >>= text
        pure [(s, c)]
      _ -> pure []

moduleP :: Value -> Parser Module
moduleP v = do
  sections <- field "sections" v >>= array
  let empty = Module [] [] [] [] [] M.empty [] M.empty
  foldM' addSection empty sections
 where
  foldM' f z = go z
   where
    go acc [] = pure acc
    go acc (x : xs) = f acc x >>= \acc' -> go acc' xs

  addSection m section = do
    (tag, payload) <- tagged section
    case tag of
      "Typespace" -> do
        ts <- field "types" payload >>= array >>= mapM algP
        pure m {modTypespace = ts}
      "Types" -> do
        ts <- array payload >>= mapM typeDefP
        pure m {modTypes = ts}
      "Tables" -> do
        ts <- array payload >>= mapM tableP
        pure m {modTables = ts}
      "Reducers" -> do
        rs <- array payload >>= mapM reducerP
        pure m {modReducers = rs}
      "Procedures" -> do
        ps <- array payload >>= mapM procedureP
        pure m {modProcedures = ps}
      "ExplicitNames" -> do
        c <- explicitNamesP payload
        pure m {modCanonical = c}
      _ -> pure m -- ignore sections codegen does not consume

-- Resolution and shape -----------------------------------------------------

-- | Follow a single @TRef@ into the typespace. A dangling ref is an error.
resolve :: Module -> Typ -> Either Text Typ
resolve m (TRef i) = case drop i (modTypespace m) of
  (t : _) | i >= 0 -> Right t
  _ -> Left ("dangling type ref " <> tshow i)
resolve _ t = Right t

{- | Whether a type can be emitted, given the set of refs already accepted as
named. Refs must point at named types; everything structural must bottom out
in primitives, arrays, options, or named refs.
-}
renderable :: Module -> [Int] -> Typ -> Either Text ()
renderable m named = go
 where
  go (TRef i)
    | i `elem` named = Right ()
    | otherwise = Left ("depends on unnamed type ref " <> tshow i)
  go (TPrim _) = Right ()
  go (TArray t) = go t
  go t@(TSum _) = case asOption t of
    Just inner -> go inner
    Nothing -> mapM_ (go . fieldTy) (sumFields t)
  go (TProduct fs) = mapM_ (go . fieldTy) fs

  sumFields (TSum fs) = fs
  sumFields _ = []

{- | Recognise the SATS @Option@ encoding: a two-variant sum @some(T)/none@
with @none@ carrying a unit product.
-}
asOption :: Typ -> Maybe Typ
asOption (TSum [Field (Just "some") t, Field (Just "none") (TProduct [])]) = Just t
asOption _ = Nothing

{- | Fixpoint: register every declared type as a named candidate, drop the ones
whose bodies are not renderable, and repeat until stable.
-}
computeNamedDropped :: Module -> Module
computeNamedDropped m = m {modNamed = named, modDropped = dropped}
 where
  candidates = map tdRef (modTypes m)
  named = fix candidates
  fix cur =
    let next = filter (\r -> ok cur r) cur
     in if length next == length cur then cur else fix next
  ok cur r = case bodyOf r of
    Nothing -> False
    Just body -> case renderable m (filter (/= r) cur) body of
      Right () -> True
      Left _ -> False
  bodyOf r = case drop r (modTypespace m) of
    (t : _) | r >= 0 -> Just t
    _ -> Nothing
  dropped =
    M.fromList
      [ (r, reasonOf r)
      | r <- candidates
      , r `notElem` named
      ]
  reasonOf r = case bodyOf r >>= (either Just (const Nothing) . renderable m named) of
    Just msg -> msg
    Nothing -> "unsupported type"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
