# HKD Table Rows + `App`-Derived Modules — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an author define a whole SpacetimeDB module — tables (with columns/attributes in the row type), reducers, and lifecycle hooks — from one `App` record, deriving the server module, the client handles, and a compile-time "every reducer implemented" check.

**Architecture:** rel8-style HKD rows (`data Widget f`) carry attributes in field types via a `Column` type family with two views (`Value` erases attrs → raw insert/decode rows; `Schema` preserves attrs → Generics reads them). A plain `App` record's field names are the table/reducer names. `deriveApp` fills handles from selectors; `deriveModule app handlers` lowers everything to the existing `ModuleSchema` IR + `encodeModule`, and a generic position-wise link makes a missing/mistyped handler a compile error. The old `defineModule`/`ColumnAttr` convenience is removed (superseded); the retained low-level path is raw `ModuleSchema` + `encodeModule`.

**Tech Stack:** GHC 9.10.3 (native, nix devshell `.#dev`), `GHC.Generics`, DataKinds/TypeFamilies, hspec, fourmolu. Design doc: `docs/superpowers/specs/2026-09-21-hkd-module-derivation-design.md`.

**Conventions:**
- All commands run in the dev shell, e.g. `nix develop .#dev --command cabal test`.
- Project field convention: `DuplicateRecordFields` + `NoFieldSelectors` + `OverloadedRecordDot`, `deriving stock (…, Generic)`, `deriving anyclass SpacetimeType`. Never prefix field names.
- Format touched files with `nix develop .#dev --command fourmolu -i <files>` before each commit.
- Commit trailers (append to every commit message):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016WZ3cT8fjfvnPjMTPJFi54
  ```
- Type-level code sometimes needs small adjustments to satisfy GHC; the TDD loop (write test → see it fail → implement → see it pass) is the source of truth. If a code block here doesn't compile verbatim, fix minimally to make the stated test pass without changing the test's intent.

---

## File Structure

**Create:**
- `server/src/SpacetimeDB/Server/HKD.hs` — view kinds, `Column` family, `ColAttr`/`ColInfo`, per-column reflection (`ColumnSpec`/`ReifyAttrs`), the Generic column walk (`GCols`/`columnsOf`), and the `LifecycleHook` handle + lifecycle reflection.
- `server/src/SpacetimeDB/Server/Derive.hs` — `deriveApp`, `deriveModule`, `MkHandle`, the Generic walks over `App` (tables/reducers) and `Handlers`, the type-level position-wise match, and `camelToSnake`.
- `test/SpacetimeDB/Server/HKDSpec.hs` — column reflection + `columnsOf` unit tests.
- `test/SpacetimeDB/Server/DeriveSpec.hs` — `deriveApp` names, `deriveModule` golden byte-match, dispatch, and negative compile proofs harness.

**Modify:**
- `server/src/SpacetimeDB/Server/Table.hs` — re-kind `Table :: Row -> Type`; ops on `row Value`.
- `server/src/SpacetimeDB/Server.hs` — export the new frontend modules' public API.
- `hs-spacetime.cabal` — add `HKD`, `Derive` modules; add test modules; remove `Module`.
- `src/SpacetimeDB/Client/Typed.hs` — `subscribeTable` over HKD rows (`row Value`).
- `server/example/WidgetModule.hs`, `server/example/PersonModule.hs` — rewrite on HKD/`App`.
- `test/SpacetimeDB/Server/TableSpec.hs`, `test/SpacetimeDB/Client/TypedSpec.hs` — HKD rows.

**Remove:**
- `server/src/SpacetimeDB/Server/Module.hs` and `test/SpacetimeDB/Server/ModuleSpec.hs` (replaced by `Derive.hs` / `DeriveSpec.hs`).

---

## Phase 1 — HKD row foundation

### Task 1: View kinds, `Column` family, `ColAttr`/`ColInfo`

**Files:**
- Create: `server/src/SpacetimeDB/Server/HKD.hs`
- Modify: `hs-spacetime.cabal` (add `SpacetimeDB.Server.HKD` to `library spacetime-server` exposed-modules)
- Test: `test/SpacetimeDB/Server/HKDSpec.hs`

- [ ] **Step 1: Add the module to the cabal file**

In `hs-spacetime.cabal`, under `library spacetime-server` → `exposed-modules:`, add `SpacetimeDB.Server.HKD` (after `SpacetimeDB.Server.Reducer`).

- [ ] **Step 2: Write the failing test**

Create `test/SpacetimeDB/Server/HKDSpec.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}

module SpacetimeDB.Server.HKDSpec (spec) where

import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server.HKD
import SpacetimeDB.Server.Schema (AlgType (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import Test.Hspec

-- A row whose value view is a plain record (compile-level check).
data Widget f = Widget
  { id :: Column f Word64 '[ 'Pk, 'AutoInc]
  , name :: Column f Text '[]
  , quantity :: Column f Word32 '[]
  }
  deriving stock (Generic)

deriving anyclass instance SpacetimeType (Widget 'Value)

widgetValue :: Widget 'Value
widgetValue = Widget 7 "w" 3

spec :: Spec
spec = describe "Server.HKD" $ do
  it "Value view exposes raw field types" $
    (widgetValue.id, widgetValue.quantity) `shouldBe` (7, 3)

  it "reflects a Schema-view column to its AlgType and attrs" $ do
    colAlgType @(ColInfo Word64 '[ 'Pk, 'AutoInc]) `shouldBe` TU64
    colAttrs @(ColInfo Word64 '[ 'Pk, 'AutoInc]) `shouldBe` [ColPk, ColAutoInc]
```

Also register the module: in `hs-spacetime.cabal` `test-suite hs-spacetime-test` → `other-modules:`, add `SpacetimeDB.Server.HKDSpec`; and in `test/Spec.hs` add its `spec` to the aggregate (follow the existing pattern in that file — an `hspec $ do describe ...` / import list).

Note: `widgetValue.id` needs `OverloadedRecordDot`; add it plus `NoFieldSelectors` and `DuplicateRecordFields` to the test's pragma block.

- [ ] **Step 3: Run the test to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `Could not find module SpacetimeDB.Server.HKD`.

- [ ] **Step 4: Implement `HKD.hs` (this task's slice)**

Create `server/src/SpacetimeDB/Server/HKD.hs`:

```haskell
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Higher-kinded (rel8-style) table rows: columns and their attributes live in
-- the row type. A 'Column' has two views — 'Value' (raw field type; attributes
-- erased) and 'Schema' (attributes preserved so the schema can be derived).
module SpacetimeDB.Server.HKD
  ( View (..)
  , Row
  , Column
  , ColAttr (..)
  , ColInfo
  , ColAttrVal (..)
  , ColumnSpec (..)
  , ReifyAttrs (..)
  ) where

import Data.Kind (Type)
import SpacetimeDB.Server.Schema (AlgType)
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))

-- | The view a row is being looked at through.
data View = Value | Schema

-- | Kind of a higher-kinded row constructor, e.g. @Widget :: Row@.
type Row = View -> Type

-- | A column attribute (promoted to a type-level list per column).
data ColAttr = Pk | AutoInc

-- | Value-level mirror of 'ColAttr', produced by reflection.
data ColAttrVal = ColPk | ColAutoInc
  deriving stock (Eq, Show)

-- | The 'Schema'-view carrier for a column: preserves @a@ and @attrs@ at the
-- type level (its runtime value is irrelevant — schema derivation is by type).
newtype ColInfo (a :: Type) (attrs :: [ColAttr]) = ColInfo ()

-- | @Column f a attrs@ is @a@ under 'Value' and a 'ColInfo' under 'Schema'.
type family Column (f :: View) (a :: Type) (attrs :: [ColAttr]) :: Type where
  Column 'Value a _ = a
  Column 'Schema a attrs = ColInfo a attrs

-- | Reflect a single 'Schema'-view field type to its 'AlgType' and attributes.
class ColumnSpec (field :: Type) where
  colAlgType :: AlgType
  colAttrs :: [ColAttrVal]

instance (SpacetimeType a, ReifyAttrs attrs) => ColumnSpec (ColInfo a attrs) where
  colAlgType = algebraicType @a
  colAttrs = reifyAttrs @attrs

-- | Reflect a type-level attribute list to values.
class ReifyAttrs (attrs :: [ColAttr]) where
  reifyAttrs :: [ColAttrVal]

instance ReifyAttrs '[] where
  reifyAttrs = []

instance (ReifyAttr a, ReifyAttrs as) => ReifyAttrs (a ': as) where
  reifyAttrs = reifyAttr @a : reifyAttrs @as

class ReifyAttr (a :: ColAttr) where
  reifyAttr :: ColAttrVal

instance ReifyAttr 'Pk where
  reifyAttr = ColPk

instance ReifyAttr 'AutoInc where
  reifyAttr = ColAutoInc
```

(`ReifyAttr` is an internal helper; no need to export it.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: PASS — `Server.HKD` examples green; overall suite still 0 failures.

- [ ] **Step 6: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/HKD.hs test/SpacetimeDB/Server/HKDSpec.hs
git add server/src/SpacetimeDB/Server/HKD.hs test/SpacetimeDB/Server/HKDSpec.hs hs-spacetime.cabal test/Spec.hs
git commit -m "feat(hkd): Column family + view kinds + per-column reflection

<trailers>"
```

---

### Task 2: Generic column walk (`columnsOf`)

**Files:**
- Modify: `server/src/SpacetimeDB/Server/HKD.hs`
- Test: `test/SpacetimeDB/Server/HKDSpec.hs`

- [ ] **Step 1: Add the failing test**

Append to `HKDSpec.hs`'s `spec` (and add `import SpacetimeDB.Server.Schema (Field (..))`):

```haskell
  it "walks a Schema-view row into ordered (name, type, attrs) columns" $
    columnsOf @Widget
      `shouldBe` [ ("id", TU64, [ColPk, ColAutoInc])
                 , ("name", TString, [])
                 , ("quantity", TU32, [])
                 ]
```

This needs the `Widget` from Task 1 (already `deriving stock Generic`; the walk uses `Rep (Widget 'Schema)`, which is available for any `Generic` HKD row). Add `DataKinds`/`TypeApplications` already present.

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `Variable not in scope: columnsOf`.

- [ ] **Step 3: Implement the Generic walk**

In `HKD.hs`, extend the export list with `columnsOf` and `GCols`, add imports and code:

```haskell
-- add to imports
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics
import GHC.TypeLits (KnownSymbol, symbolVal)
import SpacetimeDB.Server.Schema (AlgType, Field (..))

-- | Ordered columns of a row, read from its 'Schema' view: (name, type, attrs).
columnsOf
  :: forall (row :: Row)
   . (Generic (row 'Schema), GCols (Rep (row 'Schema)))
  => [(Text, AlgType, [ColAttrVal])]
columnsOf = gcols @(Rep (row 'Schema))

-- | Generic walk over a row's 'Schema'-view representation.
class GCols (rep :: Type -> Type) where
  gcols :: [(Text, AlgType, [ColAttrVal])]

instance (GCols f) => GCols (D1 meta f) where
  gcols = gcols @f

instance (GCols f) => GCols (C1 meta f) where
  gcols = gcols @f

instance (GCols a, GCols b) => GCols (a :*: b) where
  gcols = gcols @a ++ gcols @b

instance
  (KnownSymbol name, ColumnSpec t)
  => GCols (S1 ('MetaSel ('Just name) su ss ds) (K1 i t))
  where
  gcols = [(T.pack (symbolVal (Proxy @name)), colAlgType @t, colAttrs @t)]
```

Add `{-# LANGUAGE TypeOperators #-}` and `{-# LANGUAGE FlexibleContexts #-}` to `HKD.hs`.

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/HKD.hs
git add -A server/src/SpacetimeDB/Server/HKD.hs test/SpacetimeDB/Server/HKDSpec.hs
git commit -m "feat(hkd): Generic column walk (columnsOf) over the Schema view

<trailers>"
```

---

## Phase 2 — re-kind `Table`

### Task 3: `Table :: Row -> Type` and value ops on `row Value`

**Files:**
- Modify: `server/src/SpacetimeDB/Server/Table.hs`
- Modify: `test/SpacetimeDB/Server/TableSpec.hs`

- [ ] **Step 1: Rewrite the test to use an HKD row**

Replace the `Event` declaration and `eventTable` in `test/SpacetimeDB/Server/TableSpec.hs`:

```haskell
-- add pragmas: DataKinds, FlexibleInstances, StandaloneDeriving
data Event f = Event
  { who :: Column f Text '[]
  , at :: Column f Int64 '[]
  }
  deriving stock (Generic)

deriving stock instance Show (Event 'Value)
deriving stock instance Eq (Event 'Value)
deriving anyclass instance SpacetimeType (Event 'Value)

eventTable :: Table Event
eventTable = table "event"
```

Add `import SpacetimeDB.Server.HKD (Column, View (..))`. Update the two test bodies: `insertRow eventTable (Event "alice" 42)` now produces an `Event 'Value` (inference is fine); `scanRows eventTable` returns `[Event 'Value]`; the `shouldBe` comparisons work via the standalone `Eq`/`Show`. Values `Event "a" 1` etc. remain unchanged (the `Value` view makes them plain records).

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — kind mismatch: `Table` expects `Type`, `Event` has kind `Row`.

- [ ] **Step 3: Re-kind `Table` and its ops**

Rewrite `server/src/SpacetimeDB/Server/Table.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SpacetimeDB.Server.Table
  ( Table
  , table
  , tableName
  , insertRow
  , deleteRow
  , scanRows
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import SpacetimeDB.BSATN.Decoder (runExact)
import SpacetimeDB.BSATN.Encoder (runEncoder)
import SpacetimeDB.Server.HKD (Row, View (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
import SpacetimeDB.Server.Types

-- | A typed handle to a table whose HKD row constructor is @row@. Phantom in @row@.
newtype Table (row :: Row) = Table Text

table :: Text -> Table row
table = Table

tableName :: Table row -> Text
tableName (Table n) = n

insertRow :: (SpacetimeType (row 'Value)) => Table row -> row 'Value -> ReducerM ()
insertRow (Table n) row = do
  t <- tableId n
  insert t (runEncoder encodeVal row)

deleteRow :: (SpacetimeType (row 'Value)) => Table row -> row 'Value -> ReducerM ()
deleteRow (Table n) row = do
  t <- tableId n
  delete t (runEncoder encodeVal row)

scanRows :: forall row. (SpacetimeType (row 'Value)) => Table row -> ReducerM [row 'Value]
scanRows (Table n) = do
  t <- tableId n
  raws <- scan (decodeVal @(row 'Value)) t
  traverse decodeRow raws
 where
  decodeRow bs = case runExact (decodeVal @(row 'Value)) bs of
    Right r -> pure r
    Left e -> throwError ("row decode failed: " <> T.pack (show e))
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: `Server.Table` PASS. (`Module`/`ModuleSpec` and the examples will now fail to build — that is expected and fixed in later tasks. If the whole suite won't link because of `Module.hs`, proceed to Task 4 which removes it, then re-run.)

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/Table.hs test/SpacetimeDB/Server/TableSpec.hs
git add -A server/src/SpacetimeDB/Server/Table.hs test/SpacetimeDB/Server/TableSpec.hs
git commit -m "refactor(hkd): re-kind Table to Row; value ops on the Value view

<trailers>"
```

---

## Phase 3 — App handles, `deriveApp`, `deriveModule`

### Task 4: Remove `Module.hs`; add `LifecycleHook` + lifecycle reflection

**Files:**
- Remove: `server/src/SpacetimeDB/Server/Module.hs`, `test/SpacetimeDB/Server/ModuleSpec.hs`
- Modify: `hs-spacetime.cabal` (drop `SpacetimeDB.Server.Module` from lib exposed-modules and `SpacetimeDB.Server.ModuleSpec` from test other-modules; add `SpacetimeDB.Server.Derive` to lib, `SpacetimeDB.Server.DeriveSpec` to test)
- Modify: `server/src/SpacetimeDB/Server/HKD.hs` (add `LifecycleHook` + lifecycle reflection)
- Modify: `test/Spec.hs` (drop `ModuleSpec`, add `DeriveSpec`; add `HKDSpec` if not already)

- [ ] **Step 1: Remove the superseded module + spec and de-register**

```bash
git rm server/src/SpacetimeDB/Server/Module.hs test/SpacetimeDB/Server/ModuleSpec.hs
```
Edit `hs-spacetime.cabal`: remove the `SpacetimeDB.Server.Module` line from `library spacetime-server`; remove `SpacetimeDB.Server.ModuleSpec` from the test `other-modules`; add `SpacetimeDB.Server.Derive` (lib) and `SpacetimeDB.Server.DeriveSpec` (test). Edit `test/Spec.hs`: remove the `ModuleSpec` import + its `describe`, add `DeriveSpec`.

- [ ] **Step 2: Write the failing test (lifecycle reflection)**

Append to `HKDSpec.hs` (`import SpacetimeDB.Server.Schema (Lifecycle (..))`):

```haskell
  it "reflects a LifecycleHook's phase and name" $ do
    lifecycleVal @'Init `shouldBe` Init
    lifecycleHookName (initHook :: LifecycleHook 'Init) `shouldBe` "seed"
```
where the test defines `initHook = lifecycleHook "seed"`. Add `lifecycleHook`, `lifecycleHookName`, `LifecycleHook`, `lifecycleVal`, `KnownLifecycle` to the `HKD` import.

- [ ] **Step 3: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `LifecycleHook`/`lifecycleVal` not in scope.

- [ ] **Step 4: Implement the lifecycle handle + reflection in `HKD.hs`**

Add to `HKD.hs` (export `LifecycleHook`, `lifecycleHook`, `lifecycleHookName`, `KnownLifecycle`, `lifecycleVal`):

```haskell
import SpacetimeDB.Server.Schema (Lifecycle (..))

-- | A lifecycle-reducer handle, phantom in its 'Lifecycle' phase (kind reuses the
-- promoted 'Lifecycle' value type). Its argument is always @()@.
newtype LifecycleHook (l :: Lifecycle) = LifecycleHook Text

lifecycleHook :: Text -> LifecycleHook l
lifecycleHook = LifecycleHook

lifecycleHookName :: LifecycleHook l -> Text
lifecycleHookName (LifecycleHook n) = n

-- | Reflect a type-level 'Lifecycle' phase to its value.
class KnownLifecycle (l :: Lifecycle) where
  lifecycleVal :: Lifecycle

instance KnownLifecycle 'Init where lifecycleVal = Init
instance KnownLifecycle 'OnConnect where lifecycleVal = OnConnect
instance KnownLifecycle 'OnDisconnect where lifecycleVal = OnDisconnect
```

(`Lifecycle` used as a kind needs `DataKinds`, already on.)

- [ ] **Step 5: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: `Server.HKD` PASS. (Examples still broken — fixed in Phase 4.)

- [ ] **Step 6: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/HKD.hs test/SpacetimeDB/Server/HKDSpec.hs
git add -A
git commit -m "feat(hkd): LifecycleHook handle + lifecycle reflection; drop defineModule

<trailers>"
```

---

### Task 5: `deriveApp` (fill handles from field selectors)

**Files:**
- Create: `server/src/SpacetimeDB/Server/Derive.hs`
- Create: `test/SpacetimeDB/Server/DeriveSpec.hs`

- [ ] **Step 1: Write the failing test**

Create `test/SpacetimeDB/Server/DeriveSpec.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE NoFieldSelectors #-}

module SpacetimeDB.Server.DeriveSpec (spec) where

import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server.Derive
import SpacetimeDB.Server.HKD
import SpacetimeDB.Server.Reducer (Reducer, reducerName)
import SpacetimeDB.Server.Schema (Lifecycle (..))
import SpacetimeDB.Server.SpacetimeType (SpacetimeType)
import SpacetimeDB.Server.Table (Table, tableName)
import Test.Hspec

data Widget f = Widget
  { id :: Column f Word64 '[ 'Pk, 'AutoInc]
  , name :: Column f Text '[]
  , quantity :: Column f Word32 '[]
  }
  deriving stock (Generic)

deriving anyclass instance SpacetimeType (Widget 'Value)

data AddWidgetArgs = AddWidgetArgs {name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

data App = App
  { widget :: Table Widget
  , addWidget :: Reducer AddWidgetArgs
  , init :: LifecycleHook 'Init
  }
  deriving stock (Generic)

app :: App
app = deriveApp

spec :: Spec
spec = describe "Server.Derive.deriveApp" $
  it "fills handle names from field selectors (camelCase to snake_case)" $ do
    tableName app.widget `shouldBe` "widget"
    reducerName app.addWidget `shouldBe` "add_widget"
    lifecycleHookName app.init `shouldBe` "init"
```

Add `OverloadedRecordDot` to the pragmas.

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `Could not find module SpacetimeDB.Server.Derive`.

- [ ] **Step 3: Implement `deriveApp` + `camelToSnake` in `Derive.hs`**

Create `server/src/SpacetimeDB/Server/Derive.hs`:

```haskell
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Derive a whole module from an @App@ record. Field names are the table/reducer
-- names; 'deriveApp' fills handles from selectors and 'deriveModule' lowers the
-- @App@ (plus a sibling handlers record) to a 'ModuleDef'.
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: `Server.Derive.deriveApp` PASS.

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/Derive.hs test/SpacetimeDB/Server/DeriveSpec.hs
git add -A
git commit -m "feat(hkd): deriveApp fills handles from field selectors

<trailers>"
```

---

### Task 6: `deriveModule` — schema derivation (byte-match goldens)

**Files:**
- Modify: `server/src/SpacetimeDB/Server/Derive.hs`
- Modify: `test/SpacetimeDB/Server/DeriveSpec.hs`

- [ ] **Step 1: Write the failing golden test**

Add to `DeriveSpec.hs`. First extend the App fixture with a reducer set that reproduces the widget golden (add_widget then init), and add an event fixture reproducing the event golden. Add imports:

```haskell
import qualified Data.ByteString as BS
import SpacetimeDB.Server (ModuleDef, describeBytes)
import SpacetimeDB.Server.Types (ReducerM)
```

Handlers record + module for widget (handlers are stubs; behaviour is covered in Task 7):

```haskell
data WidgetHandlers = WidgetHandlers
  { addWidget :: AddWidgetArgs -> ReducerM ()
  , init :: () -> ReducerM ()
  }
  deriving stock (Generic)

widgetModule :: ModuleDef
widgetModule =
  deriveModule
    app
    WidgetHandlers
      { addWidget = \_ -> pure ()
      , init = \() -> pure ()
      }
```

Event fixture:

```haskell
data Event f = Event {who :: Column f Text '[], at :: Column f Int64 '[]}
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (Event 'Value)

newtype RecordArgs = RecordArgs {note :: Text}
  deriving stock (Generic) deriving anyclass (SpacetimeType)
newtype RecordNArgs = RecordNArgs {count :: Word32}
  deriving stock (Generic) deriving anyclass (SpacetimeType)

data EventApp = EventApp
  { event :: Table Event
  , deleteAll :: Reducer ()
  , record :: Reducer RecordArgs
  , recordN :: Reducer RecordNArgs
  }
  deriving stock (Generic)

eventApp :: EventApp
eventApp = deriveApp

data EventHandlers = EventHandlers
  { deleteAll :: () -> ReducerM ()
  , record :: RecordArgs -> ReducerM ()
  , recordN :: RecordNArgs -> ReducerM ()
  }
  deriving stock (Generic)

eventModule :: ModuleDef
eventModule =
  deriveModule eventApp EventHandlers
    { deleteAll = \() -> pure ()
    , record = \_ -> pure ()
    , recordN = \_ -> pure ()
    }
```

Add `Int64` import (`Data.Int`). Tests:

```haskell
  it "widget App derives schema bytes byte-identical to the Rust golden" $ do
    golden <- BS.readFile "phase2/golden/widget.schema.bsatn"
    describeBytes widgetModule `shouldBe` golden

  it "event App derives schema bytes byte-identical to the Rust golden" $ do
    golden <- BS.readFile "phase1/golden/event.schema.bsatn"
    describeBytes eventModule `shouldBe` golden
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build spacetime-server`
Expected: FAIL — `Variable not in scope: deriveModule`.

- [ ] **Step 3: Implement `deriveModule` schema half**

Extend `Derive.hs` exports with `deriveModule`. Add imports:

```haskell
import Data.Typeable (Typeable, tyConName, typeRep, typeRepTyCon)
import Data.Word (Word16, Word32)
import SpacetimeDB.BSATN.Decoder (Decoder)
import SpacetimeDB.Server.HKD
  ( ColAttrVal (..)
  , GCols
  , KnownLifecycle
  , LifecycleHook
  , Row
  , View (..)
  , columnsOf
  , lifecycleVal
  )
import SpacetimeDB.Server.Internal (BoundReducer (..), ModuleDef (..), ReducerM)
import SpacetimeDB.Server.Schema
import SpacetimeDB.Server.SpacetimeType (SpacetimeType (..))
```

The schema derivation walks the `App` value into module parts. Implement two Generic walks and the assembler:

```haskell
-- | A table's contribution to the module schema.
data TablePart = TablePart
  { rowType :: AlgType          -- product type for the typespace
  , typeName :: Text            -- exported type name (e.g. "Widget")
  , tbl :: Word32 -> TableSchema -- given its ref/product index
  }

-- | Collect table parts from an App value (in field order).
class GAppTables (rep :: * -> *) where
  gAppTables :: rep x -> [TablePart]

instance (GAppTables f) => GAppTables (D1 m f) where gAppTables (M1 x) = gAppTables x
instance (GAppTables f) => GAppTables (C1 m f) where gAppTables (M1 x) = gAppTables x
instance (GAppTables a, GAppTables b) => GAppTables (a :*: b) where
  gAppTables (a :*: b) = gAppTables a ++ gAppTables b

-- tables contribute; reducers/lifecycle contribute nothing here
instance {-# OVERLAPPABLE #-} GAppTables (S1 m (K1 i t)) where
  gAppTables _ = []

instance
  ( Generic (row 'Schema)
  , GCols (Rep (row 'Schema))
  , Typeable (row 'Value)
  )
  => GAppTables (S1 m (K1 i (Table row)))
  where
  gAppTables (M1 (K1 t)) = [tablePartFor @row (tableName t)]

tablePartFor
  :: forall (row :: Row)
   . (Generic (row 'Schema), GCols (Rep (row 'Schema)), Typeable (row 'Value))
  => Text
  -> TablePart
tablePartFor tname =
  TablePart
    { rowType = TProduct fields
    , typeName = T.pack (tyConName (typeRepTyCon (typeRep (Proxy @(row 'Value)))))
    , tbl = \ref ->
        TableSchema
          { name = tname
          , productTypeRef = ref
          , primaryKey = pkCols
          , indexes =
              [ IndexDef
                  { sourceName = Just (tname <> "_" <> cn <> "_idx_btree")
                  , accessorName = Just cn
                  , columns = [ix]
                  }
              | (ix, cn) <- pkNamed
              ]
          , constraints = [ConstraintDef {sourceName = Nothing, uniqueColumns = [ix]} | (ix, _) <- pkNamed]
          , sequences =
              [ SequenceDef
                  { sourceName = Nothing
                  , column = ix
                  , start = Nothing
                  , minValue = Nothing
                  , maxValue = Nothing
                  , increment = 1
                  }
              | (ix, _) <- autoNamed
              ]
          , tableType = UserTable
          , tableAccess = PublicTable
          , isEvent = False
          }
    }
 where
  cols = columnsOf @row
  fields = [Field (Just cn) ty | (cn, ty, _) <- cols]
  indexed = zip [0 :: Word16 ..] cols
  pkNamed = [(ix, cn) | (ix, (cn, _, attrs)) <- indexed, ColPk `elem` attrs]
  pkCols = map fst pkNamed
  autoNamed = [(ix, cn) | (ix, (cn, _, attrs)) <- indexed, ColAutoInc `elem` attrs]

-- | Collect reducer schemas from an App value (skips tables), in field order.
class GAppReducers (rep :: * -> *) where
  gAppReducers :: rep x -> [ReducerSchema]

instance (GAppReducers f) => GAppReducers (D1 m f) where gAppReducers (M1 x) = gAppReducers x
instance (GAppReducers f) => GAppReducers (C1 m f) where gAppReducers (M1 x) = gAppReducers x
instance (GAppReducers a, GAppReducers b) => GAppReducers (a :*: b) where
  gAppReducers (a :*: b) = gAppReducers a ++ gAppReducers b

instance {-# OVERLAPPABLE #-} GAppReducers (S1 m (K1 i t)) where
  gAppReducers _ = []

instance
  (SpacetimeType args)
  => GAppReducers (S1 m (K1 i (Reducer args)))
  where
  gAppReducers (M1 (K1 r)) =
    [ReducerSchema {name = reducerName r, params = paramFields (algebraicType @args), lifecycle = Nothing}]

instance
  (KnownLifecycle l)
  => GAppReducers (S1 m (K1 i (LifecycleHook l)))
  where
  gAppReducers (M1 (K1 h)) =
    [ReducerSchema {name = lifecycleHookName h, params = [], lifecycle = Just (lifecycleVal @l)}]

paramFields :: AlgType -> [Field]
paramFields (TProduct fs) = fs
paramFields other = [Field Nothing other]
```

Add the imports `reducerName`, `lifecycleHookName`, `tableName` and the `deriveModule` assembler (dispatch half filled in Task 7 — for now use an empty reducer list so goldens can be checked independently):

```haskell
deriveModule
  :: forall app handlers
   . (Generic app, GAppTables (Rep app), GAppReducers (Rep app))
  => app
  -> handlers
  -> ModuleDef
deriveModule appVal _handlers =
  ModuleDef
    { schemaBytes = encodeModule schema
    , reducers = [] -- dispatch list added in Task 7
    }
 where
  parts = gAppTables (from appVal)
  schema =
    ModuleSchema
      { typespace = map (.rowType) parts
      , types = zipWith (\i p -> TypeDefSchema {scope = [], name = p.typeName, ref = i, customOrdering = True}) [0 ..] parts
      , tables = zipWith (\i p -> p.tbl i) [0 ..] parts
      , reducers = gAppReducers (from appVal)
      }
```

Add `{-# LANGUAGE OverloadedRecordDot #-}`, `{-# LANGUAGE OverloadedStrings #-}`, `{-# LANGUAGE UndecidableInstances #-}`, `{-# LANGUAGE KindSignatures #-}` to `Derive.hs`.

Note on overlap: the `{-# OVERLAPPABLE #-}` catch-all `S1` instances let table-only walks skip reducers and vice-versa. If GHC reports overlap it cannot resolve, replace the catch-alls with explicit "do-nothing" instances for the two other handle types (e.g. `GAppTables (S1 m (K1 i (Reducer args)))` and `... (LifecycleHook l)` returning `[]`) rather than `OVERLAPPABLE`.

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -30`
Expected: both golden byte-match tests PASS. If bytes differ, diff against the field/attr construction in the removed `Module.hs` (git history) — the schema assembly must match it exactly (index name `{table}_{col}_idx_btree`, unique constraint per PK, sequence per auto-inc, `customOrdering = True`).

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/Derive.hs test/SpacetimeDB/Server/DeriveSpec.hs
git add -A
git commit -m "feat(hkd): deriveModule derives schema bytes from App (goldens match)

<trailers>"
```

---

### Task 7: `deriveModule` — dispatch list + compile-time exhaustiveness

**Files:**
- Modify: `server/src/SpacetimeDB/Server/Derive.hs`
- Modify: `test/SpacetimeDB/Server/DeriveSpec.hs`

- [ ] **Step 1: Write the failing dispatch test**

Add to `DeriveSpec.hs` (imports `SpacetimeDB.Server (dispatchReducer)`, `SpacetimeDB.Server.Internal (Backend (..), TableId (..))`, `SpacetimeDB.Server (mkContext)`, `Data.IORef`, `SpacetimeDB.BSATN.Encoder (runEncoder)`):

```haskell
  it "dispatches reducer 1 (add_widget) through the derived handler" $ do
    inserted <- newIORef []
    let be =
          Backend
            { tableId = \_ -> pure (Right (TableId 1))
            , insert = \_ row -> modifyIORef' inserted (++ [row]) >> pure (Right ())
            , scan = \_ -> pure (Right BS.empty)
            , delete = \_ _ -> pure (Right ())
            , log = \_ -> pure ()
            }
        args = runEncoder encodeVal (AddWidgetArgs "a" 10)
    -- add_widget is reducer id 0 (first reducer field of App)
    r <- dispatchReducer widgetModuleLive 0 (mkContext 0 0 0 0 0 0 0) args be
    r `shouldBe` Right ()
    rows <- readIORef inserted
    length rows `shouldBe` 1
```

where `widgetModuleLive` is a variant whose `addWidget` handler actually inserts:

```haskell
widgetModuleLive :: ModuleDef
widgetModuleLive =
  deriveModule app WidgetHandlers
    { addWidget = \(AddWidgetArgs n q) -> insertRow app.widget (Widget 0 n q)
    , init = \() -> insertRow app.widget (Widget 0 "seed" 1)
    }
```
Add `import SpacetimeDB.Server.Table (insertRow)` to the spec. `Widget 0 n q` is a `Widget 'Value`.

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: FAIL — `r` is `Left "unknown reducer id 0"` (dispatch list still empty from Task 6).

- [ ] **Step 3: Implement the handler walk + type-level match**

In `Derive.hs`, add a Generic walk that turns the handlers record into `[BoundReducer]` in field order:

```haskell
class GHandlers (rep :: * -> *) where
  gHandlers :: rep x -> [BoundReducer]

instance (GHandlers f) => GHandlers (D1 m f) where gHandlers (M1 x) = gHandlers x
instance (GHandlers f) => GHandlers (C1 m f) where gHandlers (M1 x) = gHandlers x
instance (GHandlers a, GHandlers b) => GHandlers (a :*: b) where
  gHandlers (a :*: b) = gHandlers a ++ gHandlers b

instance
  (SpacetimeType a)
  => GHandlers (S1 m (K1 i (a -> ReducerM ())))
  where
  gHandlers (M1 (K1 h)) = [BoundReducer (decodeVal @a) h]
```

Add the position-wise type-level match between App's reducer fields and the handlers' fields. Define type families extracting ordered `(name, argType)` pairs, and require equality:

```haskell
import Data.Kind (Type)
import GHC.TypeLits (Symbol)

type family (xs :: [k]) ++ (ys :: [k]) :: [k] where
  '[] ++ ys = ys
  (x ': xs) ++ ys = x ': (xs ++ ys)

-- (name, argType) of each Reducer/Lifecycle field of an App rep, in order.
type family AppSigs (rep :: Type -> Type) :: [(Symbol, Type)] where
  AppSigs (D1 m f) = AppSigs f
  AppSigs (C1 m f) = AppSigs f
  AppSigs (a :*: b) = AppSigs a ++ AppSigs b
  AppSigs (S1 ('MetaSel ('Just n) su ss ds) (K1 i (Reducer a))) = '[ '(n, a)]
  AppSigs (S1 ('MetaSel ('Just n) su ss ds) (K1 i (LifecycleHook l))) = '[ '(n, ())]
  AppSigs (S1 m (K1 i (Table row))) = '[]

-- (name, argType) of each handler field, in order (arg stripped from a -> ReducerM ()).
type family HandlerSigs (rep :: Type -> Type) :: [(Symbol, Type)] where
  HandlerSigs (D1 m f) = HandlerSigs f
  HandlerSigs (C1 m f) = HandlerSigs f
  HandlerSigs (a :*: b) = HandlerSigs a ++ HandlerSigs b
  HandlerSigs (S1 ('MetaSel ('Just n) su ss ds) (K1 i (a -> ReducerM ()))) = '[ '(n, a)]
```

Note: `AppSigs` needs `snakeCase(n)` to match `HandlerSigs`' `n`? No — both take their names from *Haskell field selectors*, and the `App` reducer field and its `Handlers` counterpart use the *same* Haskell name (e.g. both `addWidget`). So the raw selector symbols already match; snake conversion only affects the *wire* name, not the type-level match. Good.

Update `deriveModule`'s constraints and body:

```haskell
deriveModule
  :: forall app handlers
   . ( Generic app
     , Generic handlers
     , GAppTables (Rep app)
     , GAppReducers (Rep app)
     , GHandlers (Rep handlers)
     , AppSigs (Rep app) ~ HandlerSigs (Rep handlers)
     )
  => app
  -> handlers
  -> ModuleDef
deriveModule appVal handlers =
  ModuleDef
    { schemaBytes = encodeModule schema
    , reducers = gHandlers (from handlers)
    }
 where
  ... (schema as before)
```

The `AppSigs (Rep app) ~ HandlerSigs (Rep handlers)` equality makes a missing handler (length mismatch), a wrong-order/renamed handler (symbol mismatch), or a wrong argument type (type mismatch) a **compile error**.

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: dispatch test PASS; golden tests still PASS.

- [ ] **Step 5: Add negative compile proofs**

Create a REPL harness check (mirrors the `HasField` proof used earlier). Add to `DeriveSpec.hs` a comment block documenting the two negative cases, and verify them out-of-band:

Run:
```bash
nix develop .#dev --command bash -c 'cabal repl spacetime-server <<EOF
:set -XDataKinds -XDeriveGeneric -XDerivingStrategies -XTypeApplications -XFlexibleContexts
-- reuse a local App with two reducers but Handlers missing one, or with a wrong arg type,
-- and confirm deriveModule fails with a type error (AppSigs ~ HandlerSigs mismatch).
EOF'
```
Expected: a type error mentioning the mismatch (missing handler or wrong arg type). Record the observed error text in a comment in `DeriveSpec.hs` so the guarantee is documented. (If crafting this in the bare REPL is awkward, instead add a `test/negative/` `.hs` snippet and compile it with `ghc -fno-code` expecting failure, as done for the earlier column-attr proof.)

- [ ] **Step 6: Format and commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server/Derive.hs test/SpacetimeDB/Server/DeriveSpec.hs
git add -A
git commit -m "feat(hkd): deriveModule dispatch list + compile-time exhaustiveness

<trailers>"
```

---

## Phase 4 — client + examples + wiring

### Task 8: HKD-aware client `subscribeTable`

**Files:**
- Modify: `src/SpacetimeDB/Client/Typed.hs`
- Modify: `test/SpacetimeDB/Client/TypedSpec.hs`

- [ ] **Step 1: Update the compile-proof test to HKD rows**

In `test/SpacetimeDB/Client/TypedSpec.hs`, change `Widget` to an HKD row and `widgetTable :: Table Widget`, and the subscription callback to `[Widget 'Value]`:

```haskell
-- pragmas: add DataKinds, StandaloneDeriving
data Widget f = Widget
  { id :: Column f Word64 '[]
  , name :: Column f Text '[]
  , quantity :: Column f Word32 '[]
  }
  deriving stock (Generic)
deriving stock instance Show (Widget 'Value)
deriving anyclass instance SpacetimeType (Widget 'Value)

widgetTable :: Table Widget
widgetTable = table "widget"
```
Update `clientConfig`'s callback annotation to `(inserts :: [Widget 'Value])`. Add `import SpacetimeDB.Server.HKD (Column, View (..))`.

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop .#dev --command cabal build 2>&1 | tail -20`
Expected: FAIL — `subscribeTable`'s `row` is kind `Type`, `Widget` is kind `Row`.

- [ ] **Step 3: Re-kind `subscribeTable`**

In `src/SpacetimeDB/Client/Typed.hs`, update the row parameter to a `Row` and decode the `Value` view:

```haskell
-- add pragmas: DataKinds
import SpacetimeDB.Server.HKD (Row, View (..))

subscribeTable
  :: forall (row :: Row)
   . (SpacetimeType (row 'Value))
  => Table row
  -> Text
  -> ([row 'Value] -> [row 'Value] -> IO ())
  -> Config
  -> Config
subscribeTable tbl query onRows =
  subscribeQuery (tableName tbl) query $ \case
    TypedInitial ins -> onRows (decodeRows ins) []
    TypedChange ins dels -> onRows (decodeRows ins) (decodeRows dels)
 where
  decodeRows :: [ByteString] -> [row 'Value]
  decodeRows = map decodeRow
  decodeRow bs = case runExact (decodeVal @(row 'Value)) bs of
    Right r -> r
    Left e -> error ("subscribeTable: row decode failed: " <> show e)
```

`callTyped` is unchanged (it is keyed on `Reducer args`, not tables).

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: `Client.Typed` PASS; full suite green.

- [ ] **Step 5: Format and commit**

```bash
nix develop .#dev --command fourmolu -i src/SpacetimeDB/Client/Typed.hs test/SpacetimeDB/Client/TypedSpec.hs
git add -A
git commit -m "feat(hkd): client subscribeTable over HKD rows (Value view)

<trailers>"
```

---

### Task 9: Update `Server.hs` re-exports

**Files:**
- Modify: `server/src/SpacetimeDB/Server.hs`

- [ ] **Step 1: Re-export the frontend**

Rewrite `server/src/SpacetimeDB/Server.hs` to re-export the HKD authoring surface:

```haskell
module SpacetimeDB.Server
  ( module SpacetimeDB.Server.Types
  , module SpacetimeDB.Server.HKD
  , module SpacetimeDB.Server.Table
  , module SpacetimeDB.Server.Reducer
  , module SpacetimeDB.Server.Derive
  , mkContext
  , dispatchReducer
  , describeBytes
  ) where

import SpacetimeDB.Server.Derive
import SpacetimeDB.Server.Dispatch (describeBytes, dispatchReducer, mkContext)
import SpacetimeDB.Server.HKD
import SpacetimeDB.Server.Reducer
import SpacetimeDB.Server.Table
import SpacetimeDB.Server.Types
```

If any export overlaps cause ambiguity (e.g. `Lifecycle` from `Schema` vs re-exports), restrict the offending module's re-export list explicitly rather than re-exporting everything.

- [ ] **Step 2: Run to verify it builds + tests pass**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -20`
Expected: full suite green.

- [ ] **Step 3: Commit**

```bash
nix develop .#dev --command fourmolu -i server/src/SpacetimeDB/Server.hs
git add -A server/src/SpacetimeDB/Server.hs
git commit -m "feat(hkd): re-export HKD authoring surface from SpacetimeDB.Server

<trailers>"
```

---

### Task 10: Rewrite the wasm example modules on HKD/`App`

**Files:**
- Modify: `server/example/WidgetModule.hs`
- Modify: `server/example/PersonModule.hs`

- [ ] **Step 1: Rewrite `WidgetModule.hs`**

Replace the schema/reducer portion (keep the FFI export boilerplate at the bottom unchanged):

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE NoFieldSelectors #-}

module WidgetModule where

import Data.Int (Int16)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import SpacetimeDB.Server
import SpacetimeDB.Server.ABI (runCallReducer, runDescribe)

data Widget f = Widget
  { id :: Column f Word64 '[ 'Pk, 'AutoInc]
  , name :: Column f Text '[]
  , quantity :: Column f Word32 '[]
  }
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (Widget 'Value)

data AddWidgetArgs = AddWidgetArgs {name :: Text, quantity :: Word32}
  deriving stock (Generic)
  deriving anyclass (SpacetimeType)

data App = App
  { widget :: Table Widget
  , addWidget :: Reducer AddWidgetArgs
  , init :: LifecycleHook 'Init
  }
  deriving stock (Generic)

app :: App
app = deriveApp

data Handlers = Handlers
  { addWidget :: AddWidgetArgs -> ReducerM ()
  , init :: () -> ReducerM ()
  }
  deriving stock (Generic)

theModule :: ModuleDef
theModule =
  deriveModule app Handlers
    { addWidget = \(AddWidgetArgs n q) -> insertRow app.widget (Widget 0 n q)
    , init = \() -> insertRow app.widget (Widget 0 "seed" 1)
    }
```
Keep the `foreign export ccall hs_describe ...` / `hs_call_reducer ...` block from the current file verbatim. Ensure `SpacetimeType`, `Column`, `View`, `Table`, `Reducer`, `LifecycleHook`, `deriveApp`, `deriveModule`, `insertRow`, `ModuleDef`, `ReducerM` all come via `import SpacetimeDB.Server` (add explicit imports if the umbrella doesn't cover one).

- [ ] **Step 2: Rewrite `PersonModule.hs` (event module) on HKD/`App`**

Mirror the event fixture from Task 6, preserving the real handler bodies from the current file (scan+delete for `delete_all`, timestamp insert for `record`, positive-count guard for `record_n`). App field order: `event, deleteAll, record, recordN`. Keep the FFI export block verbatim. Row:

```haskell
data Event f = Event {who :: Column f Text '[], at :: Column f Int64 '[]}
  deriving stock (Generic)
deriving anyclass instance SpacetimeType (Event 'Value)
```
Handlers use `scanRows app.event`, `deleteRow app.event`, `insertRow app.event (Event n micros)`. `ask`/`throwError`/`Timestamp` come via `SpacetimeDB.Server` / `SpacetimeDB.BSATN.Types`.

- [ ] **Step 3: Verify the examples build under the wasm shell**

Run: `nix develop .#wasm --command wasm32-wasi-cabal build widget-module-example person-module-example 2>&1 | tail -30`
Expected: both compile. (This is the only check that exercises the example files, since they are `buildable: False` outside `flag(wasm)`. If the `.#wasm` toolchain is unavailable in the execution environment, note it and rely on the native `DeriveSpec` fixtures — which are byte-identical module definitions — as the compile proof, then flag that the wasm build was not run.)

- [ ] **Step 4: Commit**

```bash
nix develop .#dev --command fourmolu -i server/example/WidgetModule.hs server/example/PersonModule.hs
git add -A server/example/WidgetModule.hs server/example/PersonModule.hs
git commit -m "feat(hkd): rewrite widget + event example modules on HKD/App

<trailers>"
```

---

### Task 11: Full green + final formatting sweep

**Files:** none (verification)

- [ ] **Step 1: Run the whole native suite**

Run: `nix develop .#dev --command cabal test 2>&1 | tail -30`
Expected: all examples pass, 0 failures. Confirm the count is ≥ the pre-change 98 (the HKD/Derive specs add examples; the removed `ModuleSpec` subtracts its 2 — net positive).

- [ ] **Step 2: Format sweep**

Run: `nix develop .#dev --command fourmolu -i $(git diff --name-only origin/main -- '*.hs')`
Then `nix develop .#dev --command cabal test 2>&1 | tail -5` to confirm still green.

- [ ] **Step 3: Commit any formatting**

```bash
git add -A
git commit -m "style(hkd): fourmolu sweep

<trailers>"   # skip if nothing changed
```

---

## Self-Review Notes (author)

- **Spec coverage:** row HKD (Tasks 1–3), attribute reflection + schema derivation with byte-match goldens (Tasks 2, 6), `App`/`deriveApp` (Task 5), exhaustiveness + dispatch (Task 7), client (Task 8), examples (Task 10), `defineModule`/`ColumnAttr` removal (Task 4). Non-goals (`Insert` view, multi-arg reducers, `Unique`/`Indexed`, order-independent matching) are intentionally absent.
- **`ColAttr` scope:** trimmed to `Pk`/`AutoInc` (the attributes the goldens exercise); `Unique`/`Indexed` deferred. This is a deliberate narrowing of the spec's illustrative 4-value enum.
- **Type-level risk:** the `GAppTables`/`GAppReducers` overlap handling (Task 6) and `AppSigs ~ HandlerSigs` match (Task 7) are the parts most likely to need iteration; each has a fallback note inline.
- **Regression net:** event + widget goldens byte-matched through the new path (Task 6); person golden untouched (raw `SchemaSpec`).
