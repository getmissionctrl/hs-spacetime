---
name: spacetimedb-client-sdk
description: Build a SpacetimeDB client SDK / client library in a new language from scratch, targeting the v2 WebSocket protocol (`v2.bsatn.spacetimedb`). Covers the four layers to build and the order to build them in — a BSATN codec with decoder/encoder combinators, the v2 wire protocol (frame compression, every client→server and server→client message with exact byte layouts), a connection manager (subscriptions, typed row dispatch, reducer/procedure/one-off-query calls, reconnect with subscription replay, token persistence and identity), and a bindings generator that reads the V10 module schema from `spacetime describe --json` — plus the hermetic and live-server test strategy. Client-only — server modules are out of scope. Use when writing or extending a SpacetimeDB client for a language that has no official SDK (Gleam, Elixir, OCaml, Haskell, Zig, Swift, Kotlin, …), when porting one, or when debugging BSATN/protocol framing against a real server.
---

# Building a SpacetimeDB Client SDK

A language-agnostic recipe for writing a **full-featured SpacetimeDB client
library**, distilled from a working Gleam implementation
(`~/Work/OpenSource/gleam-spacetimedb`, ~4.7k lines of source, ~230 hermetic
tests, plus a live-server suite). Everything here was verified against a real
server and the upstream Rust source; where the upstream *docs* disagree with
the *wire*, this says so.

The reference for what an officially-supported client looks like from the
*user's* side is a TypeScript/Svelte project at
`~/Work/Study/escape-the-moon` (`src/lib/Connection.svelte` for the builder
and token handling, `src/module_bindings/` for the generated code). Use it to
calibrate the surface you're aiming for; the sections below say where a new
SDK should match it and where it can legitimately differ.

## Scope

**In scope — a complete client:**

- A **BSATN** codec: every primitive, strings, bytes, arrays, options,
  products, sums, plus decoder/encoder *combinators* so generated code is
  compositional rather than hand-spliced bytes. → [bsatn.md](bsatn.md)
- The **v2 protocol**: WebSocket handshake, per-frame compression byte, all
  five client messages and all eight server messages. → [protocol.md](protocol.md)
- A **client**: builder API, subscriptions (declared up front *and* added or
  dropped at runtime), typed per-table row dispatch, reducer calls, procedure
  calls, one-off SQL queries, reconnect with exponential backoff that
  restores subscriptions under the same ids, and a server-issued token that
  survives reconnects and can be persisted across runs. → [client.md](client.md)
- A **bindings generator** reading the V10 `RawModuleDefV10` JSON: row
  records, decoders, encoders, enums, nested named products, and one typed
  call wrapper per client-callable reducer and procedure. → [codegen.md](codegen.md)
- **Tests** that pin the wire format without a server and prove the whole
  stack against a real one. → [testing.md](testing.md)

**Out of scope, deliberately:** writing server modules. This is the client
half only. The one exception is a tiny *fixture* module (one table, one
reducer, one seeded row) that the integration tests publish so there is
something to talk to.

**Not yet in the reference implementation** (and so not covered in depth
here, but you should plan the seams for them): a primary-key-keyed client
row cache with synchronous reads, derived `Updated(old, new)` events and
per-table `on_insert`/`on_update`/`on_delete` callbacks, discarding a query
set's rows on a late `SubscriptionError`, and the `SendDroppedRows`
unsubscribe flag. The official SDKs have the first two; see "Parity targets"
below.

## The mental model

SpacetimeDB is a database that is also the backend. A client opens one
WebSocket, subscribes to SQL `SELECT`s, and the server streams the matching
rows — an initial snapshot, then every later insert and delete — as BSATN, a
compact positional binary encoding. Writes go through *reducers*
(transactional functions in the module) and *procedures* (non-transactional);
a reducer's own row changes come back **inside its reply**, not as a separate
message. Every client request carries a client-chosen `request_id` and the
reply echoes it; every subscription carries a client-chosen `query_set_id`
that the server names in every update for it.

Four layers, each knowing only the one below:

```
client      connection owner + socket, builder API, typed dispatch, calls, reconnect
protocol    v2 frames: compression byte, message tags, struct layouts, row-list splitting
bsatn       byte-level codec + combinators
codegen     schema JSON -> source (a pure function; its OUTPUT uses bsatn + client)
```

Build them in that order, bottom-up, and test each before starting the next.
The codec can be finished and property-tested in an afternoon with no server;
the protocol layer can be pinned against hex fixtures; only the client needs
a socket, and only the end-to-end check needs SpacetimeDB running.

## Build order and definition of done

1. **BSATN codec.** Primitives (all widths, LE), string/bytes/list with `u32`
   length prefixes, `u8`-tagged sums, options (`some` = tag **0**), products
   as bare concatenation. A `Decoder<T>` that returns `(value, rest)`; a
   `run_exact` that demands all bytes consumed; `decode_rows` returning the
   failing row's index. Encoders as `T -> bytes` with `concat`, `contramap`,
   `encode_sum`. **Done when** `decode(encode(x)) == x` holds under a
   property test that hits `0`, `1`, `-1`, `2^(n-1)`, `2^n - 1` for every
   width. (Beware 32-bit PRNGs — build wide random ints from 30-bit chunks.)
2. **Protocol.** `decode_frame`: strip compression byte (0 none / 1 brotli /
   2 gzip), inflate, decode `ServerMessage` by `u8` tag 0..7, unknown tag →
   `Unhandled(tag)` *not* an error. Encoders for client tags 0..4. Split
   `BsatnRowList` into per-row byte strings here. **Done when** captured
   frames decode and a hand-built `Subscribe` matches the expected hex.
3. **Client.** A long-lived *connection owner* holding token, subscription
   list, `query_set_id` and `request_id` counters, pending-call registry and
   backoff state; a per-connection *socket* holding the routing table. See
   [client.md](client.md) for the ordering rules — they are the whole
   difficulty. **Done when** the live checks in [testing.md](testing.md)
   pass: seed row delivered, token round-trips to the same identity, a cut
   connection comes back subscribed, a reducer's rows arrive before its
   reply, add/unsubscribe at runtime behaves.
4. **Codegen.** Parse `spacetime describe --json` (V10 sections), build a
   small schema model, resolve refs, emit records + decoders + encoders +
   call wrappers. Fatal on unsupported types unless `--skip`. Output must be
   *formatter-stable*. **Done when** goldens generated from captured
   fixtures match byte-for-byte, the generated types round-trip, and an
   end-to-end check regenerates from the live server's schema and finds the
   committed file identical.

## The ten things that bite

Each is expanded in the reference files; this is the list to keep open.

1. **`Option` is `some` = tag 0, `none` = tag 1.** Result is `ok` = 0, `err`
   = 1. Not the other way round.
2. **Products have no framing at all** — no length, no field count, no names.
   So `Identity`, `ConnectionId`, `Timestamp`, `TimeDuration`, `Uuid` (all
   single-field products with magic `__x__` field names) are just their
   inner integer on the wire: 32, 16, 8, 8, 16 LE bytes respectively.
3. **Timestamps are microseconds**, whatever the `v2.rs` doc comments say.
4. **A reducer that returns unit answers `ReducerOutcome::Ok` with an empty
   `ret_value`**, not the distinct `OkEmpty` variant. Handle both; let the
   return decoder run on zero bytes.
5. **`ProcedureResult`'s fields are status, timestamp, duration, request_id**
   — the id comes *last*, unlike every other reply.
6. **The first byte of every server frame is a compression tag**, and small
   frames arrive uncompressed even when you asked for Brotli. Compression is
   permission, not promise.
7. **Query-parameter spellings are exact and fail as HTTP 400 before the
   upgrade**: `compression=None|Brotli|Gzip`, `confirmed=true|false`. Omit
   `confirmed` entirely to track the server's default. Don't bother with
   `light` — the v2 send path never reads it.
8. **Subscriptions belong to the connection owner, not the socket**, and are
   replayed on reconnect *under the same `query_set_id`s* (ids are
   client-chosen and per-connection, so this is legal and keeps handles
   valid). Never reuse an id even after it is freed.
9. **A reducer's row changes are inside `ReducerResult`.** Dispatch them
   through the same table routing as a `TransactionUpdate`, *before* running
   the caller's result callback. Procedure results carry no rows. One-off
   query rows must *not* go through table routing — nobody subscribed.
10. **Callbacks run on the client's own thread/process.** Any blocking API
    (read token, add subscription) round-trips to that same owner, so
    calling it from inside a callback deadlocks. Document it loudly; make
    calls callback-only and let users build blocking wrappers.

## Parity targets: what an official SDK exposes

From the TypeScript SDK 2.x as used in `escape-the-moon`:

```ts
const conn = DbConnection.builder()
  .withUri('ws://localhost:3000').withDatabaseName('spacecards')
  .withToken(localStorage.getItem(TOKEN_KEY) ?? undefined)
  .onConnect((conn, identity, token) => localStorage.setItem(TOKEN_KEY, token))
  .onConnectError((ctx, err) => { /* clear a rejected token, reload */ })
  .build();
conn.subscriptionBuilder().onApplied(() => ...).subscribe([tables.user, 'SELECT * FROM message']);
conn.db.user.onInsert((ctx, row) => ...); conn.db.user.onDelete(...); conn.db.user.onUpdate((ctx, old, new) => ...);
conn.reducers.addRecord({ data }).catch(...);     // promise per call
```

Match these **semantics**: builder → connection; token handed to `onConnect`
and persisted by the app; per-table typed callbacks; typed reducer call per
generated wrapper; subscriptions that can be added after connect and carry a
handle. You may legitimately differ in **mechanism**: the reference uses
whole-batch `on_change(Initial | Changed(inserts, deletes))` per subscription
instead of a client cache with per-row callbacks (the cache is the next thing
to add — plan the primary key into your schema model now, it's in the
`Tables` section as column indices). Generated names: the TS SDK converts
`snake_case` columns to `camelCase`; do whatever your language's formatter
wants, but take **wire names** from the schema's `ExplicitNames` section, not
from the source name.

One lesson from that project worth copying into any SDK's docs: a stored
token the server no longer recognises (the database was recreated in dev)
fails the handshake with a 401 / "Failed to verify token" **every** time until
something clears it. Give users a way to tell a rejected token from a
server-down error so their app can drop the token and reconnect anonymous
rather than spin.

## Sources of truth

Check these, not memory, when in doubt. A checkout lives at
`~/Work/ThirdParty/SpacetimeDB`.

| What | Where |
| --- | --- |
| Client/server message enums and struct field order | `crates/client-api-messages/src/websocket/v2.rs` |
| `Compression` spellings, `BsatnRowList`, `RowSizeHint`, `QuerySetId` | `crates/client-api-messages/src/websocket/common.rs` |
| `Option`/`Result` tag order | `crates/sats/src/algebraic_type.rs` (`option`, `result`) |
| Special-type field names and widths | `crates/sats/src/{timestamp,time_duration,uuid}.rs`, `crates/lib/src/{identity,connection_id}.rs` |
| Subscribe route, query params, `confirmed` default | `crates/client-api/src/routes/subscribe.rs` |
| BSATN spec (also copied into the reference repo's `docs/00300-bsatn.md`) | `docs/` in upstream |

**Variant tags are source positions in the Rust enums.** They are positional
and brittle by design; re-check them when upstream bumps. The first tag
upstream appends is the first one your `Unhandled(tag)` will see — which is
why unknown tags must be reported, never fatal.

## Reference files

- [bsatn.md](bsatn.md) — wire format table, decoder/encoder combinator
  design, special types, run helpers, property-test generators.
- [protocol.md](protocol.md) — handshake, compression byte, every message
  with byte layout, row-list splitting, the traps.
- [client.md](client.md) — owner/socket split, subscription lifecycle,
  dispatch paths, call registry, reconnect, token/identity, events and
  errors, threading contract.
- [codegen.md](codegen.md) — V10 JSON shape, schema model, resolution rules,
  what to emit for each kind of thing, naming, `--skip`, formatter stability.
- [testing.md](testing.md) — hermetic seams, goldens, roundtrip properties,
  the live harness (port program, stdin teardown, TCP proxy for cuts), check
  ordering.
