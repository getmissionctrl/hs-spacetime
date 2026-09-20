# The client: connection owner, socket, subscriptions, calls

This is the layer with all the ordering subtleties. The design below is
described in terms of two *roles*; in the reference they are two BEAM
processes (a supervisor actor and a WebSocket actor), but the same split
works as two objects in a single-threaded runtime, or an object plus a task
in an async one. What matters is **which state lives where**, because one of
them dies with every dropped connection and the other doesn't.

## The two roles

```
Connection owner (lives for the client's lifetime)
  token                      server-issued if we have one, else the user's
  subscriptions: [LiveSub]   query, query_set_id, optional (table, dispatcher)
  next_query_set_id          only ever increases
  pending calls: {request_id -> continuation}
  next_request_id
  backoff state              attempt, current delay
  current socket (optional)

Socket (one per connection; replaced on reconnect)
  a mirror of the subscription list, indexed by table name -> dispatcher
  its own counter for Subscribe/Unsubscribe request_ids
  sent_subscribes: bool      greeting seen and subscriptions sent
```

Everything a reconnect must restore lives on the owner: **token,
subscriptions, and pending calls** — the third because the answers were going
to arrive on a connection that no longer exists, and the only party that
reliably learns about every death is the owner watching the socket. Put any
of those three on the socket and a reconnect will come back as a new
identity, subscribed to whatever the builder originally said, with calls
hanging forever.

**The socket must not be able to take the owner down.** On the BEAM that
means *monitor, don't link* (the WebSocket library spawns linked and turns a
`tcp_closed` into an abnormal exit; without an explicit unlink a dropped
connection kills the owner, which kills the application — instead of
reconnecting). In other runtimes the equivalent is: every socket error is
caught and converted into a `SocketDown(reason)` message to the owner; none
propagates as an exception. Also make sure `stop()` kills the socket
explicitly, since it is no longer tied to the owner's lifetime.

## Builder API

Shape it as a builder so configuration is immutable and the final `start`
does the first connect:

```
builder(host, port, database)
  |> with_secure(bool)                 // wss; no-op once a base URI is set
  |> with_base_uri("https://proxy.example/stdb")   // replaces scheme://host:port, keeps route + params
  |> with_token(token)                 // Authorization: Bearer
  |> with_compression(None | Brotli | Gzip)
  |> with_confirmed_reads(bool)        // omitted from the URL unless called
  |> with_reconnect(NoReconnect | Reconnect{initial_ms, max_ms, max_attempts?})
  |> subscribe("SELECT * FROM t")                            // raw rows -> on_event
  |> subscribe_query(query, table, decoder, on_change)       // typed rows -> on_change
  |> on_event(fn)  |> on_error(fn)
  |> start() -> Result<Client, HandshakeFailed>
```

`start` with `NoReconnect` fails synchronously if the first handshake fails;
with reconnect it returns a handle and schedules the first retry. A sensible
default strategy: 500 ms initial, doubling to 30 s, never giving up.

The handle then offers:

```
stop(client)
token(client, timeout) -> Option<token>                     // blocking round-trip to the owner
add_subscription(client, query, timeout) -> Subscription      // blocking (needs the id allocated)
add_query_subscription(client, query, table, decoder, on_change, timeout) -> Subscription
unsubscribe(client, subscription)                             // fire-and-forget
subscription_id(subscription) -> query_set_id
call_reducer(client, name, args_bytes, returns_decoder, errors_decoder, on_result)
call_procedure(client, name, args_bytes, returns_decoder, on_result)
one_off_query(client, sql, on_result)
```

## The threading contract (document it in every callback's docs)

`on_event`, `on_change`, and every `on_result` run **on the client's own
process/thread** — row dispatch on the socket's, call results on the owner's.
Two rules follow:

1. Callbacks must be short. Real work is forwarded to the user's own
   actor/queue/event loop.
2. **No blocking API may be called from inside a callback.** `token`,
   `add_subscription` and `add_query_subscription` round-trip to the owner;
   from inside `on_result` — which the owner is running — that waits on the
   very process that has to answer, and times out.

This is also why `call_reducer` and friends are **callback-only with no
blocking variant**. A user who wants blocking wraps it: send to a channel
from `on_result`, receive on it from their own thread.

## Connect and greeting

1. Build the upgrade request (see [protocol.md](protocol.md)) with the
   **owner's** token — not the builder's — so a reconnect offers the
   server-issued one.
2. Open the socket with the owner's current subscription list.
3. On `InitialConnection(identity, connection_id, token)`:
   - Send the token to the owner **first** (it owns it across reconnects and
     answers `token()`), then emit `Connected(identity, connection_id,
     token)` to the user.
   - Send one `Subscribe` frame per subscription, in list order, **under the
     `query_set_id`s the owner already allocated**, then set
     `sent_subscribes`. Do this once per connection.
4. On success, reset the backoff (attempt 0, delay = initial).

The server's token **always replaces** the one the user supplied: it is the
authority on what your credentials now are, and for an anonymous client it is
the only copy there will ever be. Expose it two ways — in the `Connected`
event for users who want it the instant it arrives, and via `token()` for
users who want it at a moment of their choosing. Persisting it between runs
is the user's job; a stored token the server no longer recognises fails the
handshake with 401 / "Failed to verify token" until cleared, so make that
distinguishable from "server down" in `HandshakeFailed`'s reason.

## Subscriptions

Subscription **ids are chosen by the client and scoped to one connection**,
which makes two things legal and useful:

- Replay the whole list on reconnect **under the same ids**, so a
  `Subscription` handle a user holds survives a reconnect.
- Allocate ids on the owner, monotonically, starting at 1 for the builder's
  subscriptions in declaration order. **Never reuse an id**, even after
  `UnsubscribeApplied` or `SubscriptionError` frees it: there are 2^32 of
  them, and never reusing means a late frame for a closed set can't be
  mistaken for a live one.

**Adding at runtime** is a synchronous round-trip to the owner (the id has to
exist before there is a handle to return). The owner appends to its list,
tells the socket, and replies with the handle. On the socket: if the greeting
hasn't arrived yet, just join the list that the greeting handler is about to
walk (sending now *and* then would open the query twice); otherwise send the
`Subscribe` frame now. Adding while disconnected is deliberately **not an
error**: it goes on the list and the next connect opens it. The rows are the
acknowledgement — they arrive as an `Initial` like any other snapshot.

**Dropping** is fire-and-forget, and the two roles disagree on purpose about
when it happens:

- The **owner removes it immediately** — that is what stops a reconnect
  resurrecting it — and tells the socket to send `Unsubscribe` with `Default`
  flags.
- The **socket keeps the entry, and so its routing, until
  `UnsubscribeApplied` arrives**, because rows already in flight should reach
  the typed `on_change` that asked for them rather than fall out of the typed
  path and land on `on_event` as raw bytes. The one case with nothing to wait
  for is a subscription that was never sent (greeting not yet seen): remove
  it locally and send nothing.
- `UnsubscribeApplied(query_set_id)` is surfaced as an `Unsubscribed(id)`
  event; users match it against `subscription_id(handle)`.

Unsubscribing twice, or an id the owner doesn't hold, is a silent no-op.

Two `subscribe_query` registrations for the same table: the routing table is
*derived* from the live list (newest wins) and rebuilt whenever the list
changes, so a dropped subscription can never leave a stale dispatcher behind.

## Two dispatch paths, mutually exclusive per table

Rows arrive per table name inside `SubscribeApplied` (snapshot),
`TransactionUpdate`, and a `ReducerResult`'s embedded update. Route each
table's op:

- If a **typed dispatcher** is registered for the table (from
  `subscribe_query`), hand it the op and **do not** also emit on `on_event`.
- Otherwise emit `InitialRows(table, raw_rows)` / `Changed(table,
  raw_inserts, raw_deletes)` on `on_event`, suppressing ops that are empty on
  every side.

The typed dispatcher decodes with `decode_rows` and emits
`Initial(rows)` or `Changed(inserts, deletes)`. Two rules:

- **Decode both halves of a `Changed` before emitting either.** An update is
  a paired delete-of-old and insert-of-new in one frame; emitting the
  inserts and then failing on the deletes leaves the user half-applied.
- **A row-decode failure is an error event, not a dead connection.** Emit
  `RowDecodeFailed(query, batch: Initial|Insert|Delete, index, reason)` —
  carrying the *query* rather than only the table, because two `SELECT *
  FROM widget WHERE …` subscriptions share a table name — and carry on.

`EventTable` rows (an event-table's `events` list) map to `Changed(inserts:
events, deletes: [])`.

The dispatcher is **type-erased**: it closes over the user's decoder and
`on_change`, so subscriptions of different row types can share one routing
table. Pass the *current* `on_error` in as an argument rather than capturing
it, so a dispatcher never reports through a stale callback.

## Calls: reducers, procedures, one-off queries

One mechanism, three riders. A call is a *command* carrying a name, a
function `request_id -> frame_bytes`, and a type-erased continuation
`(reply, on_error) -> ()` that closes over the user's decoders and
`on_result`. The owner:

1. If there is **no socket, fails the call immediately** with "not
   connected" rather than queueing it — the user finds out now and can retry
   on the next `Connected`.
2. Otherwise allocates `request_id`, stores the continuation, has the socket
   send the frame. A failed send comes back as a failure for that id (so the
   user's `on_result` fires, not just the generic error callback).
3. On a reply for a known id, runs the continuation and forgets the id. A
   reply for an **unknown id** is an `UnmatchedReply(request_id)` event —
   never fatal (a duplicate, or a call already failed by a disconnect).
4. On **socket death, drains every pending call** with the reason, so no
   caller ever hangs. `stop()` drains too ("the client was stopped").

Reply taxonomies — design the user-facing result so a `case` is exhaustive
and "an answer" is distinguished from "no answer":

```
ReducerReply   = Returned(value)          // Ok: ret_value decoded with `returns` (possibly on 0 bytes)
               | ReturnedNothing          // OkEmpty: neither decoder runs
               | Failed(error)            // Err: declared error, decoded with `errors`; tx did NOT commit
               | CallFailed(reason)       // not connected / send failed / InternalError / disconnected / undecodable payload
ProcedureReply = Returned(value) | CallFailed(reason)     // no declared error type
QueryReply     = Returned([QueryTable(table, raw_rows)])
               | Rejected(error)          // server answered "won't run this": bad SQL, unknown table, permission
               | CallFailed(reason)
```

`Failed` and `Rejected` are **answers**: they reach `on_result` only. Every
`CallFailed` reaches `on_result` **and** is mirrored on `on_error` as
`CallFailed(name, reason)` (for a one-off query the name is the SQL, the only
thing identifying it), so a user who only wires one of the two still sees it.

Ordering and routing rules for replies:

- `ReducerResult` carrying `Ok`: **dispatch its `query_sets` through the
  table routing first, then deliver the reply.** By the time `on_result`
  runs, the user's `on_change` has already seen the rows the reducer made.
- `ProcedureResult` carries no rows — just forward the status.
- `OneOffQueryResult` rows **bypass table routing entirely**: nobody
  subscribed to them, so they go only to that call's `on_result`, raw and per
  table, in the same shape as the untyped `InitialRows` event. There is
  nothing to decode them against — the SQL is a runtime string — so the user
  finishes with `decode_rows` and a generated row decoder.

`request_id`s for calls (owner) and for Subscribe/Unsubscribe frames (socket)
are separate counters and may collide harmlessly: replies are correlated per
message type, and only calls are ever looked up in `pending`.

## Reconnect

On `SocketDown(reason)`: emit `Disconnected(reason)`, forget the socket,
drain pending calls, then:

- `NoReconnect` → stop the owner.
- `Reconnect` → if `max_attempts` is set and exceeded, stop; else emit
  `Reconnecting(attempt, delay_ms)`, schedule a connect after the current
  delay, and double the delay up to `max`. A failed *handshake* on retry
  emits `HandshakeFailed` on `on_error` and goes round again. A successful
  connect resets attempt and delay.

Then the greeting handler above replays the subscriptions — with the owner's
token, under the owner's ids. That is the entire reconnect story; nothing
else needs restoring because nothing else lived on the socket.

## Events and errors

```
Event = Connected(identity, connection_id, token)
      | Disconnected(reason) | Reconnecting(attempt, delay_ms)
      | InitialRows(table, raw_rows) | Changed(table, raw_inserts, raw_deletes)   // untyped path only
      | SubscriptionFailed(query_set_id, error) | Unsubscribed(query_set_id)
      | UnhandledMessage(tag) | UnmatchedReply(request_id)

ClientError = HandshakeFailed(reason) | DecodeFailed(reason) | SendFailed(reason)
            | RowDecodeFailed(query, batch, index, reason)
            | CallFailed(name, reason)
```

Ship `format_event` / `format_error` string renderers (counts, not row
dumps) but **not** a println logger: users have opinions about sinks.

## Endpoint handling

Two spellings converge on one base string: `HostPort(host, port, secure)`
and `BaseUri(string)`. `with_base_uri` normalises textually only (trim
trailing slashes, `ws(s)://` → `http(s)://`); whether it is a URL at all is
settled at connect time as `HandshakeFailed("invalid URL: …")`, like every
other connect failure. It is a *base*, not the whole URL: the library still
appends `/v1/database/<db>/subscribe` and its own query parameters. There is
no whole-URL escape hatch — the parameters must keep working.

## Design the state transitions as pure functions

The hermetic tests (see [testing.md](testing.md)) depend on being able to
drive the owner's and socket's logic without a network: `allocate_call(state,
command) -> (state, request_id, frame)`, `apply_reply(state, id, reply) ->
state`, `drain_pending(state, reason)`, `register_sub`, `forget_sub`,
`learn_token`, `apply_server_msg(socket_state, message)` (everything a
server message does that doesn't need the socket handle). Keep the
network-touching part a thin shell around those and mark them internal.
