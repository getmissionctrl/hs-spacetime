# The bindings generator

A pure function `schema_json -> Result<source_text, error>`, wrapped in a
thin CLI that reads stdin and writes stdout or a file:

```sh
spacetime describe --json <database> | <your-codegen> [out.ext] [--skip]
```

Input is the **V10 module definition** (`RawModuleDefV10`) that `spacetime
describe --json` emits. Output is one module of row records, decoders,
encoders, enums, nested products, and one typed call wrapper per
client-callable reducer/procedure — built entirely from the codec's
combinators so it is compositional, and formatter-clean so it can be
committed and diffed.

Note `spacetime describe` writes an unconditional "This command is UNSTABLE"
warning to **stderr**; keep stdout and stderr apart or the JSON parser sees
it.

## The V10 JSON shape

Top level is a list of **tagged sections**, in no particular order, any of
which may be absent except `Typespace`. Index them by tag first.

```json
{ "sections": [
    { "Typespace": { "types": [ <AlgebraicType>, ... ] } },
    { "Types":     [ { "source_name": { "scope": [], "source_name": "Colour" }, "ty": 1, "custom_ordering": true }, ... ] },
    { "Tables":    [ { "source_name": "pixel", "product_type_ref": 0, "primary_key": [0],
                       "indexes": [...], "constraints": [...], "sequences": [],
                       "table_type": {"User": []}, "table_access": {"Public": []},
                       "default_values": [], "is_event": false }, ... ] },
    { "Reducers":  [ { "source_name": "add_security",
                       "params": { "elements": [ {"name": {"some": "security_id"}, "algebraic_type": {"String": []}}, ... ] },
                       "visibility": {"ClientCallable": []},            // or {"Private": []}
                       "ok_return_type": {"Product": {"elements": []}},
                       "err_return_type": {"String": []} }, ... ] },
    { "Procedures": [ { "source_name": "summarise", "params": {...}, "return_type": {"Ref": 6},
                        "visibility": {"ClientCallable": []} }, ... ] },
    { "LifeCycleReducers": [ { "lifecycle_spec": {"Init": []}, "function_name": "init" } ] },
    { "ExplicitNames": { "entries": [ { "Table":    { "source_name": "pixel", "canonical_name": "pixel" } },
                                       { "Function": { "source_name": "add_security", "canonical_name": "add_security" } } ] } }
] }
```

**`AlgebraicType`** is a single-key tagged object everywhere it appears:

```
{"U64": []}  {"I32": []}  {"F64": []}  {"Bool": []}  {"String": []}      primitives; the value is an empty list
{"Ref": 3}                                                               index into Typespace.types
{"Array": <AlgebraicType>}
{"Product": {"elements": [ {"name": {"some": "id"} | {"none": []}, "algebraic_type": <T>}, ... ]}}
{"Sum":     {"variants": [ {"name": {"some": "red"}, "algebraic_type": <T>}, ... ]}}
```

Names are SATS-JSON options: `{"some": "x"}` or `{"none": []}`. Product
elements and sum variants share the same `{name, algebraic_type}` shape.

Points about the sections:

- **`Types`** maps a *declared* name to a typespace ref. Every named
  user type — table rows, nested structs, enums, *and each callable's
  parameter product* — gets an entry. Note `source_name` is nested
  (`source_name.source_name`).
- **`Tables`** gives `product_type_ref` (the row type) and `primary_key` as
  a list of column indices. Keep the primary key in your model even if you
  don't use it yet: a client row cache needs it. `is_event` marks event
  tables. `table_access` is `Public`/`Private`; only public tables are
  subscribable, but the schema lists both.
- **`Reducers`** carry `ok_return_type` and `err_return_type` separately;
  today every reducer's are unit and `String`, but read them from the schema
  with no special-casing so you follow upstream the day that changes.
- **`Procedures`** carry a single `return_type`; user-level errors are part
  of that value.
- **`visibility`** is `Private` for lifecycle hooks (`init`, `client_connected`,
  …) and scheduled reducers, `ClientCallable` for everything else. **Drop
  `Private` ones silently** — a client was never allowed to call them, so
  their absence is the schema being obeyed, not something unsupported, and
  it must not trip the fatal/`--skip` path.
- **`ExplicitNames`** is the one section that is an *object wrapping a list*
  (`entries`), not the list itself. `canonical_name` is what goes **on the
  wire** (in `CallReducer.reducer`, and as the table name in updates);
  `source_name` is what the module source called it. They coincide unless
  the module renamed something (`#[reducer(name = "…")]`), which is exactly
  the case a generator that guessed would get silently wrong. Name the
  generated function from the source name; put the canonical name in the
  string literal.

## Schema model

Parse into something this small:

```
Typ      = Ref(int) | Array(Typ) | Product([Field]) | Sum([Variant]) | Prim(string)
Field    = { name: Option<string>, typ: Typ }         Variant = same
Table    = { source_name, ref, primary_key: [int] }
Reducer  = { source_name, params: [Field], visibility, ok_return: Typ, err_return: Typ }
Procedure= { source_name, params: [Field], return: Typ, visibility }
Module   = { typespace: [Typ], tables, reducers, procedures,
             wire_names: {source_name -> canonical_name},
             declared: {ref -> name},              // from Types
             named:    {ref -> name},              // refs that WILL generate a top-level type (computed)
             dropped:  {ref -> name} }             // named candidates that failed (computed)
```

`resolve(Ref(n))` follows refs through the typespace until it reaches a
structural type; a dangling ref is an error.

## Recognising the shapes

In order, when rendering a type / decoder / encoder for a `Typ`:

1. **A `Ref` to a `named` type** → reference the generated type and its
   `decoder_name()` / `encode_name` by name. Don't inline it again.
2. **A `Ref` to a `dropped` type** → error "depends on X, which was
   skipped". Honest, and better than the "anonymous product" the structure
   alone would suggest.
3. **Primitive** → the language type; decoder/encoder names derived from the
   lowercased wire name (`"U64"` → `u64` / `encode_u64`).
4. **`Array(T)`** → list type; `list(dec)` / `encode_list(x, enc)`.
   `Array(U8)` may be worth special-casing as bytes.
5. **`Product([])`** (unit) → your unit type; decoder `success(unit)`;
   encoder emits zero bytes. Appears as reducer return types and unit enum
   payloads.
6. **Special product** — single element named `__identity__`,
   `__connection_id__`, `__timestamp_micros_since_unix_epoch__`,
   `__time_duration_micros__` → the opaque type, `map(u256, Identity.from_int)`
   etc., encoder `encode_u256(Identity.to_int(x))`.
7. **Transparent wrapper** — single element whose name is `__something__`
   and not one of the above (e.g. `__uuid__: U128`) → render the inner type.
8. **`Option`** — a `Sum` whose variants are exactly `[some(T), none(unit)]`
   by name → `Option<T>`; `optional(dec)` / `encode_optional(x, enc)`.
   Options are handled inline at use sites, never emitted as named types.
9. **Any other `Product`** with no name → error "anonymous product types are
   not supported". Any other `Sum` with no name → error "general sum types
   are not supported". (In practice module bindings name every user type,
   so these are hand-written-schema cases.)

## What generates, and from what

Targets, in emission order — tables first sorted by name, then declared
types in schema order, then callables sorted by name — every one emitted
independently so a failure skips one block, not the run:

- **Table** (`Tables` entry → its product) → a record type, a decoder
  `snake(name)()` reading the fields in order with `then`/`success`, an
  encoder `encode_snake(name)(value)` concatenating them. Unnamed fields
  become `field<n>`.
- **Declared product** that isn't a table row → the same record/decoder/
  encoder (a nested product is just a record that happens not to be a table).
- **Declared sum** that isn't an `Option` → a custom type with one
  constructor per variant (unit variants bare, payload variants `Name(T)`),
  a `sum` decoder dispatching on the tag with an `UnknownVariant` fallthrough,
  an encoder matching each constructor to `encode_variant(i, payload)`.
- **Client-callable reducer** → one function taking the client handle, the
  schema's parameters as **labelled/named arguments in wire order**, and
  `on_result`. Body: encode the parameters into the `args` product with
  `concat`, call `client.call_reducer(name: <canonical>, args, returns:
  <ok decoder>, errors: <err decoder>, on_result)`.
- **Client-callable procedure** → same with `call_procedure` and a single
  return decoder.

Which `Types` entries are **dropped** as targets (their refs still resolve at
use sites, they just don't get their own block):

- a ref that belongs to a **table** (the table already generates it under
  the table's name);
- a **callable's parameter product** — matched on *both* the PascalCase
  name and the structure, so a user type that merely shares a reducer's name
  isn't caught. There is deliberately no generated argument record: the
  labelled parameters *are* the record, and its decoder name would collide
  with the wrapper's;
- an `Option`, the unit product, a special type, a transparent wrapper.

## The fixpoint: dropping dependents

Named types reference each other, so "which refs generate" can't be decided
in one pass: a product with an enum field, an enum variant carrying a
product, a table row made of both. Do it by iteration — register every
candidate as `named`, try to generate each, drop the failures, repeat until
the set stops shrinking. A type whose dependency was skipped is then skipped
too, rather than emitted calling a decoder that was never written. The final
survivors are `named`; the rest are `dropped` (for the "depends on X" message).

## Unsupported types: fatal by default

Silently emitting a module that is quietly missing some tables is worse than
an error. Without `--skip`, any skipped target aborts the run with one line
per offender and the hint to re-run with the flag. With `--skip`, the rest
generates and each skip is recorded as a `//// Skipped <name>: <reason>`
line in the output's header comment, so the gap is visible in the file.

## Naming

- `pascal("user_identity")` = `UserIdentity`; leave an already-PascalCase
  name intact (uppercase each `_`-segment's first letter, don't lowercase
  the rest).
- `snake("IdentityProvider")` = `identity_provider` (underscore before each
  interior uppercase).
- Escape your language's reserved words (append `_`).
- Parameter names: unnamed → `arg<n>`; anything colliding with an earlier
  parameter or with the wrapper's own arguments (`client`, `on_result`)
  gains trailing underscores until it doesn't.
- Import only what the output uses: track a `needs` set (`option`,
  `identity`, `timestamp`, `client`, …) as you render and build the header
  from it, sorted.

## Formatter stability

Emit exactly what your language's formatter would emit — in the reference
that means reproducing its 80-column wrapping rule for calls and list
literals (inline if it fits, else one item per line with trailing commas).
Then the committed goldens are stable, `format --check` passes on generated
files, and a user's diff after regenerating shows only real schema changes.

## Testing the generator

Three layers, each catching something the others can't:

1. **Goldens.** Fixture schemas under `test/fixtures/*.schema.json` →
   committed `test/*_generated.<ext>`, compared byte-for-byte. Cover:
   primitives + arrays + options + specials (`sample`), enums (`enums`),
   nested named products and enums with payloads (`products`), a
   transparent wrapper *and* a deliberately unsupported table exercising
   `--skip` (`wrappers`). **Fixtures are captured `spacetime describe --json`
   output from small purpose-built modules, never hand-written JSON**: a
   field read from the wrong place is a silently wrong model rather than a
   parse error, which is the drift the tool exists to prevent. Need a new
   shape? Publish a module with it and re-capture.
2. **Round-trip properties over the generated modules.** The golden proves
   the output is stable; only `decode(encode(x)) == x` over the generated
   types proves the encoder and decoder agree. An encoder that writes
   columns in a different order from the decoder is still well-formed BSATN.
3. **End-to-end against a live server.** Generate from the running fixture
   server's `describe`, assert the committed `fixture_generated` is
   byte-identical, then *use that committed module* — its row type, its
   decoder handed to `subscribe_query`, its reducer wrapper — to subscribe,
   call, and read the inserted row back. The comparison ties the committed
   code to a real schema; running it proves the code works. See
   [testing.md](testing.md).

Regenerating after an intentional generator change means re-running all the
goldens **and** the live one (the harness has a `regenerate` mode that boots a
server, describes, generates, tears down).
