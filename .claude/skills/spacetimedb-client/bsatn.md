# BSATN: the codec layer

BSATN (Binary Spacetime Algebraic Type Notation) is how every row, every
argument and every protocol message is encoded. It is positional and
schema-dependent: **the bytes do not describe themselves**. A decoder that
reads the columns in the wrong order, or the wrong width, decodes *garbage*
rather than failing — which is why the generator in [codegen.md](codegen.md)
exists and why the round-trip property test matters more than usual.

## Wire format

| Type | Encoding |
| --- | --- |
| `Bool` | 1 byte, `0` or `1`. Anything else is an error. |
| `U8`/`I8` … `U64`/`I64` | 1/2/4/8 bytes, **little-endian**, two's complement for signed. |
| `U128`/`I128`, `U256`/`I256` | 16 / 32 bytes LE. Needs bignum support in your language. |
| `F32`/`F64` | 4 / 8 bytes, IEEE 754, little-endian. |
| `String` | `u32` byte length + that many UTF-8 bytes. Invalid UTF-8 is an error. |
| `Bytes` (array of `U8`) | `u32` length + raw bytes. Same layout as a string. |
| `Array<T>` | `u32` element count + each element back to back. |
| `Product` (struct/tuple/row) | Fields concatenated **in schema order**. No length, no count, no names, no padding. |
| `Sum` (enum/tagged union) | `u8` tag = variant index, then that variant's payload (nothing for a unit variant). |
| `Option<T>` | A sum: tag **0 = `some(T)`**, tag **1 = `none`**. |
| `Result<T, E>` | A sum: tag 0 = `ok(T)`, tag 1 = `err(E)`. |
| Unit `()` | The empty product: **zero bytes**. |

Two consequences that trip people up:

- Because a product has no framing, a **single-field product is
  indistinguishable from its field**. SpacetimeDB uses this for its special
  types (below).
- Because unit is zero bytes, a reducer "returning nothing" can legitimately
  return a zero-length `ret_value`, and your decoder for it must succeed on
  empty input. (See the `OkEmpty` trap in [protocol.md](protocol.md).)

## Special types

These are single-field products whose field has a magic `__x__` name. On the
wire each is just the inner value; in the schema JSON they appear as a
`Product` with one named element. Recognise them by the field name and map
to an opaque type in your language so users can't mix an `Identity` up with a
row id.

| Marker field | Inner type | Bytes | Client type |
| --- | --- | --- | --- |
| `__identity__` | `U256` | 32 LE | `Identity` — render as 64 lowercase hex chars, zero-padded |
| `__connection_id__` | `U128` | 16 LE | `ConnectionId` — 32 hex chars |
| `__timestamp_micros_since_unix_epoch__` | `I64` | 8 LE | `Timestamp` — **microseconds** since Unix epoch, negative = pre-epoch |
| `__time_duration_micros__` | `I64` | 8 LE | `TimeDuration` — microseconds |
| `__uuid__` | `U128` | 16 LE | Treat as a *transparent wrapper*: expose the inner value (or your language's UUID type). Note upstream renders it via **big-endian** bytes of the u128 when printing as a UUID string. |

Rule of thumb for anything *else* shaped `{ __something__: T }`: it is a
newtype; unwrap it to `T`. Keep a small set of accessors (`from_int`,
`to_int`, `to_hex`, `compare`) on the opaque types and nothing more —
formatting timestamps as calendar dates is the user's calendar library's job.

## Decoder design: `bytes -> (value, rest)`

Make a decoder a function from input bytes to **either** a `(value,
remaining_bytes)` pair **or** a typed error. Threading the remainder is what
lets decoders compose without anyone tracking offsets.

```
type Decoder<T> = fn(bytes) -> Result<(T, bytes), DecodeError>

DecodeError = UnexpectedEnd            // not enough bytes
            | InvalidBool(byte)
            | InvalidUtf8
            | UnknownVariant(tag)      // a sum tag the caller didn't handle
            | Custom(string)           // trailing bytes, wrong count, ...
```

Then the combinators. Four are enough to write every generated decoder:

- `success(v)` — consumes nothing, yields `v`. The final step of a chain.
- `then(d, f)` — run `d`, hand its value to `f`, which picks the next decoder.
  This is monadic bind; if your language has `do`/`use`/`for`-comprehension
  syntax, this is what it desugars to.
- `map(d, f)` — transform the value, leave the bytes alone.
- `sum(pick)` — read a `u8` tag, ask `pick(tag)` for the payload decoder (or
  an `UnknownVariant` error), run it.

A generated row decoder then reads as the row in schema order:

```gleam
pub fn security() -> Decoder(Security) {
  use security_id <- then(string)
  use description <- then(string)
  use code        <- then(optional(string))
  use scale       <- then(u8)
  success(Security(security_id, description, code, scale))
}
```

and an enum decoder as a `sum`:

```gleam
pub fn colour() -> Decoder(Colour) {
  use tag <- sum
  case tag {
    0 -> Ok(success(Red))
    1 -> Ok(map(u32, Rgb))
    _ -> Error(UnknownVariant(tag))
  }
}
```

Derived decoders you'll want: `list(elem)` (`u32` count then `elem` n times,
accumulate in reverse and flip), `optional(some)` (the two-variant `sum`),
`bytes`, `take_bytes(n)`.

**Never pattern-match raw bytes in callers.** Every place outside the codec
that needs to read bytes should do it through a `Decoder`. That discipline is
what makes the protocol layer and the generated code testable in isolation.

## Encoder design: `value -> bytes`

Mirror image. An `Encoder<T>` is `fn(T) -> bytes`. Primitives are bare
functions (`encode_u32`, `encode_string`, …). Products are `concat` of field
encodings in order; the only combinators you need:

- `concat(chunks)` — the workhorse. A product **is** its fields' bytes.
- `contramap(enc, f)` — point an `Encoder<B>` at an `A` by extracting the `B`
  first. The encode-side dual of `map`; used to aim a field encoder at a
  record accessor.
- `encode_product(field_encoders)` — run each against the same value, concat.
- `encode_variant(tag, payload_bytes)` and `encode_sum(pick)` — write the
  `u8` tag then the payload.
- `encode_list_of(elem)`, `encode_optional_of(some)` — lifted forms so an
  element encoder can be handed around as a value.

Keep both a **direct** form (`encode_list(values, elem)`) for readable
generated bodies and a **point-free** form (`encode_list_of(elem)`) for
nesting. A generated encoder is then a plain function whose *name* is a
first-class `Encoder`:

```gleam
pub fn encode_security(value: Security) -> BitArray {
  concat([
    encode_string(value.security_id),
    encode_string(value.description),
    encode_optional(value.code, encode_string),
    encode_u8(value.scale),
  ])
}
```

Naming convention that paid off: decoders are named after the wire type
(`u32`, `string`, `list`), encoders are the same name prefixed `encode_`,
and pure plumbing (`then`, `map`, `concat`, `contramap`) has no prefix. The
generator can then derive a primitive's decoder and encoder names from the
schema type name alone (`"U64"` → `u64` / `encode_u64`).

## Run helpers

- `run_exact(bytes, decoder) -> Result<T>` — run and **require every byte
  consumed**. Use it whenever outer framing has already told you the exact
  extent of one value: a whole server frame, one row from a split row list, a
  reducer's `ret_value`. Trailing bytes mean a schema mismatch, and silently
  ignoring them is how a wrong decoder goes unnoticed for weeks.
- `decode_rows(rows: List<bytes>, decoder) -> Result<List<T>, (index,
  error)>` — `run_exact` over each row of a split row list, reporting **which
  row** failed. The client's typed dispatch is built on this.

## Property-testing the codec

The invariant is `run_exact(encode(x), decode) == Ok(x)` for every type, with
generators that deliberately include the boundaries — `0`, `1`, `-1`,
`2^(n-1)` (top bit on), `2^n - 1`, `-2^(n-1)` — because a uniform draw over a
256-bit range essentially never lands on them, and they are exactly where an
off-by-one in width or a sign flag shows. Two implementation notes:

- Most QuickCheck-style libraries' integer generators are **32-bit
  internally**; a "bounded int up to 2^64" only ever yields values within
  2^32 of the low end. Build wide integers from 30-bit chunks
  (`high * 2^30 + low`) so the high bytes — the ones a little-endian width
  mistake drops — are exercised.
- `-1` encodes as all-ones. It catches a decoder that reads the right width
  with the wrong signedness.

Run the same property over the *generated* types once codegen exists (see
[codegen.md](codegen.md)): the golden-file comparison proves the generator
is stable, but only encoding-then-decoding proves the encoder and decoder it
wrote agree with each other.
