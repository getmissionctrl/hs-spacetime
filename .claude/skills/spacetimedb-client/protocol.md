# The v2 WebSocket protocol

Source of truth: `crates/client-api-messages/src/websocket/v2.rs` and
`common.rs` in the SpacetimeDB repo. **Every variant tag below is the
variant's position in the Rust `enum`; every struct is a BSATN product with
its fields in source order.** When upstream changes, re-derive from the file,
not from this page.

## Handshake

```
GET <base>/v1/database/<database>/subscribe?compression=Brotli[&confirmed=true|false]
Sec-WebSocket-Protocol: v2.bsatn.spacetimedb
Authorization: Bearer <token>            # optional; omit for an anonymous connection
```

- `<base>` is `http(s)://host:port` or whatever the user gave as a base URI
  (reverse proxy, path prefix). Assemble route + params in **one** place so a
  new parameter lands on both spellings. If your WebSocket library wants an
  HTTP URL and upgrades it itself, rewrite a user-supplied `ws://`/`wss://`
  to `http://`/`https://` — it is the obvious mistake for a user to make.
- `compression` must be spelled exactly `None`, `Brotli` or `Gzip` (the
  upstream enum variant names). Any other value fails deserialisation and the
  route answers **400 before the upgrade**. Default is `Brotli`.
- `confirmed` is parsed as `Option<bool>`: only `true` / `false`; `0`, `1`,
  `yes` are 400s. **Omit the parameter unless the user asked** — the server
  resolves the absent case from the negotiated protocol version (v2 default
  is confirmed reads, i.e. updates held until the transaction is durable), so
  saying nothing tracks upstream, while sending `confirmed=true` "to be
  explicit" pins you to today's default.
- `light` exists on the route but is only read on the v1 send path. For a v2
  client it changes nothing; don't expose it.
- A `connection_id` query parameter exists and is deprecated. Don't send one.
- Without a token the server mints a fresh anonymous one and a fresh
  `Identity`, delivered in `InitialConnection`. See [client.md](client.md)
  for why the client must keep and re-offer it.

All frames in both directions are **binary** WebSocket frames.

## Frame envelope (server → client)

The first byte of every server frame is a compression tag; the rest is the
payload:

| Byte | Meaning |
| --- | --- |
| `0` | Uncompressed BSATN `ServerMessage` |
| `1` | Brotli-compressed BSATN |
| `2` | Gzip-compressed BSATN |

Decode with `run_exact` — a well-formed frame is exactly one message. The
server only compresses above a size threshold, so **small frames arrive with
tag `0` whichever compression you asked for**. Support all three tags
regardless of what you requested. Client → server frames are not compressed
and carry no envelope byte: the payload starts with the `ClientMessage` tag.

## Client → server messages

`ClientMessage` sum. `QuerySetId` is a one-field product wrapping a `u32`, so
it is four bare bytes. `RawIdentifier`/`Box<str>` are strings.

| Tag | Message | Body, in order |
| --- | --- | --- |
| 0 | `Subscribe` | `request_id: u32`, `query_set_id: u32`, `query_strings: Array<String>` |
| 1 | `Unsubscribe` | `request_id: u32`, `query_set_id: u32`, `flags: UnsubscribeFlags` |
| 2 | `OneOffQuery` | `request_id: u32`, `query_string: String` |
| 3 | `CallReducer` | `request_id: u32`, `flags: u8` (**before** the name), `reducer: String`, `args: Bytes` |
| 4 | `CallProcedure` | `request_id: u32`, `flags: u8`, `procedure: String`, `args: Bytes` |

- `UnsubscribeFlags` is a sum of unit variants: `0 = Default`, `1 =
  SendDroppedRows`. With `SendDroppedRows` the server returns the rows to
  evict from a local cache in `UnsubscribeApplied.rows`; with no cache, send
  `Default` and `rows` is always `None`.
- `CallReducerFlags` / `CallProcedureFlags` are a **bare `u8`**, not a sum
  (same one byte on the wire), with a single legal value `0`. The server
  rejects anything else.
- `args` is an already-BSATN-encoded product matching the callable's
  parameter list — the generated wrapper builds it; this layer writes it as
  `Bytes` (length-prefixed). A zero-parameter call sends an empty `Bytes`
  (`00 00 00 00`).
- Each `Subscribe` may carry several query strings under one
  `query_set_id`; the reference sends one query per set so each has its own
  handle and its own error reports.

Worked example — `Subscribe { request_id: 1, query_set_id: 1, ["SELECT * FROM widget"] }`:

```
00                         tag: Subscribe
01 00 00 00                request_id = 1
01 00 00 00                query_set_id = 1
01 00 00 00                1 query string
14 00 00 00                20 bytes
53 45 4c 45 43 54 20 2a 20 46 52 4f 4d 20 77 69 64 67 65 74   "SELECT * FROM widget"
```

## Server → client messages

`ServerMessage` sum. Decode tags 0–7; **anything higher must decode as
`Unhandled(tag)` and be surfaced as an event, never as an error** — the
first variant upstream appends is the first one you'll see.

| Tag | Message | Body, in order |
| --- | --- | --- |
| 0 | `InitialConnection` | `identity: U256`, `connection_id: U128`, `token: String` |
| 1 | `SubscribeApplied` | `request_id: u32`, `query_set_id: u32`, `rows: QueryRows` |
| 2 | `UnsubscribeApplied` | `request_id: u32`, `query_set_id: u32`, `rows: Option<QueryRows>` |
| 3 | `SubscriptionError` | `request_id: Option<u32>`, `query_set_id: u32`, `error: String` |
| 4 | `TransactionUpdate` | `query_sets: Array<QuerySetUpdate>` |
| 5 | `OneOffQueryResult` | `request_id: u32`, `result: Result<QueryRows, String>` (sum: 0 ok, 1 err) |
| 6 | `ReducerResult` | `request_id: u32`, `timestamp: Timestamp` (i64 micros), `result: ReducerOutcome` |
| 7 | `ProcedureResult` | **`status: ProcedureStatus`, `timestamp: Timestamp`, `total_host_execution_duration: TimeDuration` (i64 micros), `request_id: u32`** — the id is *last* |

Nested types:

```
QueryRows            = { tables: Array<SingleTableRows> }          // one-field product: just the array
SingleTableRows      = { table: String, rows: BsatnRowList }
QuerySetUpdate       = { query_set_id: u32, tables: Array<TableUpdate> }
TableUpdate          = { table_name: String, rows: Array<TableUpdateRows> }
TableUpdateRows      = sum { 0: PersistentTable { inserts: BsatnRowList, deletes: BsatnRowList }
                             1: EventTable      { events: BsatnRowList } }
ReducerOutcome       = sum { 0: Ok { ret_value: Bytes, transaction_update: TransactionUpdate }
                             1: OkEmpty                       // zero payload bytes
                             2: Err(Bytes)                    // BSATN of the reducer's declared error type
                             3: InternalError(String) }       // panic / host failure; text is diagnostic only
ProcedureStatus      = sum { 0: Returned(Bytes)               // BSATN of the declared return type
                             1: InternalError(String) }
Timestamp            = i64 micros since Unix epoch (single-field product → bare 8 bytes)
TimeDuration         = i64 micros (same)
```

Things to get right here, each verified against a live server:

- **`ReducerOk.transaction_update` is a one-field product**, so on the wire
  `Ok` is `ret_value: Bytes` followed directly by `Array<QuerySetUpdate>`.
- **A reducer that returns `()` comes back as `Ok` with a zero-length
  `ret_value`, not as `OkEmpty`.** So the return decoder does run — on zero
  bytes — and a unit decoder must succeed on empty input. `OkEmpty` is a
  wire-size optimisation the host uses when *both* the return value and the
  query-set list are empty; keep it as a distinct constructor because it is
  a distinct encoding, but tell users to treat both as "returned nothing".
- **`ReducerOutcome::Err` means the transaction did not commit.** It is the
  reducer's *declared* error and a normal answer; decode it with the
  generated error decoder. `InternalError` is not an answer — surface it as
  a call failure.
- **`SubscriptionError.request_id` is `Some` when the initial application
  failed** (sent instead of `SubscribeApplied`) and **`None` when a query
  failed later** (after `SubscribeApplied` and some updates). In either case
  the subscription is over: drop the rows, stop expecting updates. The
  `query_set_id` may then be reused; the reference chooses never to.
- **The server may send multiple `TableUpdate`s for the same table** within
  one `QuerySetUpdate`. A per-update dispatch handles this naturally; a
  client cache keyed by table must merge them.
- **`TransactionUpdate` is only sent when at least one of the client's query
  sets was affected.** Individual `PersistentTable` entries can still be
  empty on both sides; suppress the empty ones before telling users.
- `OneOffQueryResult`'s success payload always contains exactly one
  `SingleTableRows` in practice, but the type is a list — model it as one.

## `BsatnRowList`: splitting rows

Every row batch is a `BsatnRowList = { size_hint: RowSizeHint, rows_data:
Bytes }`: a packed byte string with *no per-row markers*, plus a hint that
says where the boundaries are.

```
RowSizeHint = sum { 0: FixedSize(u16)              // every row is exactly this many bytes
                    1: RowOffsets(Array<u64>) }    // start offset of each row; end = next start, or data end
```

Read the hint, then the `Bytes` (u32 length + data), then split:

- `FixedSize(n)`: chunk the data into `n`-byte rows; `data_len / n` rows. A
  hint of `0` bytes only ever accompanies empty data (upstream guarantees
  `size != 0`), so treat `0` as "no rows" rather than dividing by it.
- `RowOffsets([o0, o1, …])`: row *i* is `data[o_i .. o_{i+1})`, the last row
  runs to the end. An empty offsets list means no rows even if data is
  non-empty (it won't be).

Split **in the protocol layer** and hand upward a `List<bytes>` per table, so
every higher layer decodes rows independently and a bad row is reported by
index rather than poisoning the frame. Decode each row with `run_exact`.

## What to expose from this layer

A `ServerMessage` sum with the eight variants above plus `Unhandled(tag)`,
whose row-carrying members hold **raw per-row byte strings** (already split)
alongside the table name; a `decode_frame(bytes) -> Result<ServerMessage,
FrameError>` where `FrameError = EmptyFrame | UnsupportedCompression(tag) |
BrotliFailed | GzipFailed | Bsatn(DecodeError)`; and five `encode_*`
functions, one per client message, taking the ids as parameters and `args`
as opaque bytes. Nothing in this layer knows about tables' schemas, callbacks
or sockets — which is what lets it be pinned by hex fixtures alone.

Compression libraries: you need a **brotli decoder** and a **gzip decoder**
(encoders aren't needed — the client never compresses). Normalise both to
the same `Result<bytes, ()>` shape so the frame decoder treats them alike.
