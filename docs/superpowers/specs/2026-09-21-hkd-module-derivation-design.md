# Design: HKD table rows + `App`-derived modules

Date: 2026-09-21
Status: approved (design), pending implementation plan

## Goal

Let an author define a whole SpacetimeDB module — tables (with their columns and
attributes), reducers, and lifecycle hooks — from Haskell types, with a single
`App` type as the source of truth that drives:

1. the **server** module (`ModuleDef`: schema bytes + dispatch list),
2. the **client** (typed handles for `callTyped`/`subscribeTable`),
3. a compile-time **"every reducer implemented"** guarantee.

No stringly-typed column names (`#id`), no table/reducer name strings, no
reducer-order coupling.

## Non-goals (v1)

Each is additive and explicitly deferred:

- `Insert` view (making auto-inc/PK columns omittable at insert time).
- Multi-argument reducers without a wrapper record.
- Nested / `Maybe` / `[]` column types.
- Retiring the low-level `ColumnAttr` / `#id` API (kept as the compilation
  target and power-user path).

## What the author writes (end-to-end)

```haskell
-- ROW: rel8-style HKD. Attributes live in the field types.
data Widget f = Widget
  { id       :: Column f Word64 '[Pk, AutoInc]
  , name     :: Column f Text   '[]
  , quantity :: Column f Word32 '[]
  } deriving stock Generic
deriving anyclass instance SpacetimeType (Widget Value)   -- value codec

data AddWidgetArgs = AddWidgetArgs { name :: Text, quantity :: Word32 }
  deriving stock Generic deriving anyclass SpacetimeType

-- APP: the single source of truth. Field names ARE the table/reducer names.
data App = App
  { widget    :: Table      Widget
  , addWidget :: Reducer    AddWidgetArgs
  , init      :: Lifecycle 'Init
  } deriving stock Generic

app :: App
app = deriveApp                       -- fills each handle's name from its selector

-- HANDLERS: sibling record. Coverage + arg-types checked against App.
data Handlers = Handlers
  { addWidget :: AddWidgetArgs -> ReducerM ()
  , init      :: () -> ReducerM ()
  } deriving stock Generic

theModule :: ModuleDef
theModule = deriveModule @App Handlers
  { addWidget = \(AddWidgetArgs n q) -> insertRow app.widget (Widget 0 n q)
  , init      = \()                  -> insertRow app.widget (Widget 0 "seed" 1)
  }

-- CLIENT: same app value, no second declaration.
callTyped   c app.addWidget (AddWidgetArgs "a" 10) print
subscribeTable app.widget "SELECT * FROM widget"
  (\ins _ -> mapM_ print (ins :: [Widget Value]))
```

## Components

### Row machinery

- `data View = Value | Schema` (promoted). Kind synonym `type Row = View -> Type`.
- Column type family:

  ```haskell
  type family Column (f :: View) (a :: Type) (attrs :: [ColAttr]) :: Type where
    Column 'Value  a _     = a                 -- raw: w.id :: Word64
    Column 'Schema a attrs = ColInfo a attrs   -- attrs preserved for derivation
  ```

- `data ColAttr = Pk | AutoInc | Unique | Indexed` (promoted).
- **Why two views:** `Value` erases attrs, giving pristine consumer/insert types;
  `Schema` preserves them so a Generics walk over the `Schema` view can read
  `'[Pk, AutoInc]` and emit the matching index / unique constraint / sequence.
  This is the concrete job the `f` parameter does here (it is *not* rel8's
  query-building role — we have no `Expr` view).

### Handles + `deriveApp`

- `newtype Table    (row :: Row)  = Table Text`
- `newtype Reducer  args          = Reducer Text`  (already exists)
- `newtype Lifecycle (p :: Phase)  = Lifecycle Text`, with
  `data Phase = Init | OnConnect | OnDisconnect` (promoted).
- `deriveApp :: (Generic a, GDeriveApp (Rep a)) => a` — walks the record and fills
  each handle's `Text` from its selector name (camelCase→snake_case). This is why
  handlers can reference `app.widget` and the client `app.addWidget` with the
  correct names and no strings.

### `deriveModule` + exhaustiveness

- `deriveModule @App handlers :: ModuleDef` reads **App's type** via Generics
  (field names + field types) to build the schema:
  - `Table` fields → tables; columns and attributes come from the HKD row's
    `Schema` view.
  - `Reducer` / `Lifecycle` fields → reducer signatures + the lifecycle section.
- A generic class links `App` ⇄ `Handlers` **by field name**: every `Reducer` /
  `Lifecycle` field of `App` must have a matching handler whose argument type
  equals the reducer's argument type. A missing or mistyped handler is a
  **compile error**, carrying a curated `TypeError` message (per the vf-haskell
  type-driven-design guidance: "always ship `TypeError` messages or the typed DSL
  gets abandoned").
- Record-construction completeness (`-Wmissing-fields`, enabled as an error)
  closes the value side, so an incompletely-built `Handlers` also fails to
  compile.
- Field order (Generic order = declaration order) drives both the schema's
  reducer section and the dispatch list, so reducer name→id stays correct by
  construction — the same invariant the current `defineModule` relies on.

## Data flow

```
App (type)  ──Generics──▶ ModuleSchema IR ──encodeModule──▶ schema bytes  ─▶ __describe_module__
   │                          ▲
   │                          │ (Table fields → tables via Widget Schema view;
   │                          │  Reducer/Lifecycle fields → reducer sigs)
   │
App (value, deriveApp) ──▶ table/reducer handles
   ├─ server: handlers close over app.widget etc.; dispatch list = App field order
   └─ client: callTyped/subscribeTable consume app.addWidget / app.widget

Handlers (value) ──generic match by name──▶ [BoundReducer] (dispatch)
```

## Layering (keeps risk low)

The HKD/`App` layer is a **frontend that emits the existing `ModuleSchema` IR**
and reuses `encodeModule`, the dispatch layer, `SpacetimeType`, and `Table`.
Nothing in `Schema.hs` / `Dispatch.hs` / `Internal.hs` changes semantically. The
low-level `defineModule` / `ColumnAttr` API remains, both for power users and as
the compilation target of the new frontend.

## Affected existing code (migration)

Because an `App` table field references the **HKD row constructor** `Widget`
(kind `Row`) — it must, to keep the attributes the `Value` view would erase — the
table handle and its value operations are re-kinded from `Type` to `Row`:

- `Table :: Row -> Type` (was `Type -> Type`).
- `insertRow :: SpacetimeType (row Value) => Table row -> row Value -> ReducerM ()`
  (and `scanRows`, client `subscribeTable`) operate on the `Value` view.

The `Value` view of a row whose columns all have `'[]` attributes is byte- and
shape-identical to today's plain record, so the migration is mechanical and does
not touch the BSATN codec or the goldens. Migrated as part of this work:

- `server/example/WidgetModule.hs`, `server/example/PersonModule.hs` → HKD rows +
  `App`/`deriveModule`.
- `Table.hs` and the client `subscribeTable` signatures.
- Tests referencing `Table`/plain rows (`TableSpec`, `ModuleSpec`,
  `Client/TypedSpec`) updated to the HKD row.

The low-level `defineModule` / `ColumnAttr` path is retained as the compilation
target; where it names a row type it uses the `Value` view.

## Error handling

- Column attribute on a non-existent column: **impossible by construction** — the
  attribute lives on a real field of the row record.
- Missing reducer handler / wrong argument type: compile error via the generic
  `App` ⇄ `Handlers` link, with a `TypeError` naming the offending field.
- Incomplete `Handlers` literal: compile error via `-Wmissing-fields` as error.
- Reducer dispatch id mismatch: prevented by construction (single Generic field
  order feeds both schema and dispatch list).

## Testing

- **Unit:** `Column`/attr reflection; `deriveApp` name derivation
  (camelCase→snake_case); generic `App` ⇄ `Handlers` matching (positive).
- **Negative compile proofs** (via a REPL/`-fno-code` harness like the one used
  for the `HasField` column check): missing handler, wrong handler arg type.
- **Golden:** `deriveModule @App` for widget / person / event byte-matches the
  committed goldens (`phase2/golden/widget.schema.bsatn`,
  `phase0/golden/person.schema.bsatn`, `phase1/golden/event.schema.bsatn`). Byte
  equivalence proves the frontend produces exactly the established schema.
- **Live (optional, later):** republish `widget-hs` from HKD source; typed client
  round-trip.

## Success criteria

1. `WidgetModule` and `PersonModule` rewritten on the HKD/`App` frontend, all
   three goldens byte-identical.
2. A wrong/missing reducer handler and a wrong handler arg type each fail to
   compile, demonstrated by a negative test.
3. Native test suite green.
4. Author-facing code contains no column-name or table/reducer-name string
   literals.
