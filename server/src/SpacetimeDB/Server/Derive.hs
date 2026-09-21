{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{- | Derive a whole module from an @App@ record. Field names are the table/reducer
names; 'deriveApp' fills handles from selectors and 'deriveModule' lowers the
@App@ (plus a sibling handlers record) to a 'ModuleDef'.
-}
module SpacetimeDB.Server.Derive
  ( deriveApp
  , MkHandle (..)
  , camelToSnake
  ) where

import Data.Char (isUpper, toLower)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics
import GHC.TypeLits (KnownSymbol, symbolVal)
import SpacetimeDB.Server.HKD (LifecycleHook, lifecycleHook)
import SpacetimeDB.Server.Reducer (Reducer, reducer)
import SpacetimeDB.Server.Table (Table, table)

-- | Build a handle of type @t@ from a wire name.
class MkHandle t where
  mkHandle :: Text -> t

instance MkHandle (Table row) where
  mkHandle = table

instance MkHandle (Reducer args) where
  mkHandle = reducer

instance MkHandle (LifecycleHook l) where
  mkHandle = lifecycleHook

-- | Convert a Haskell field name to its snake_case wire name.
camelToSnake :: Text -> Text
camelToSnake = T.pack . go . T.unpack
 where
  go [] = []
  go (c : cs)
    | isUpper c = '_' : toLower c : go cs
    | otherwise = c : go cs

-- | Fill every handle field of an @App@ record from its selector name.
deriveApp :: (Generic a, GDeriveApp (Rep a)) => a
deriveApp = to gderiveApp

class GDeriveApp (rep :: * -> *) where
  gderiveApp :: rep x

instance (GDeriveApp f) => GDeriveApp (D1 meta f) where
  gderiveApp = M1 gderiveApp

instance (GDeriveApp f) => GDeriveApp (C1 meta f) where
  gderiveApp = M1 gderiveApp

instance (GDeriveApp a, GDeriveApp b) => GDeriveApp (a :*: b) where
  gderiveApp = gderiveApp :*: gderiveApp

instance
  (KnownSymbol name, MkHandle t)
  => GDeriveApp (S1 ('MetaSel ('Just name) su ss ds) (K1 i t))
  where
  gderiveApp = M1 (K1 (mkHandle (camelToSnake (T.pack (symbolVal (Proxy @name))))))
