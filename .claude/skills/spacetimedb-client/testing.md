# Testing a SpacetimeDB client

Two suites with a hard line between them: a **hermetic** suite that needs
nothing running and is what CI executes, and an **opt-in live suite** that
boots a real SpacetimeDB, publishes a fixture module, and drives the client
against it. Everything that *can* be pinned without a server should be; the
live suite exists for the handful of behaviours nothing else can observe.

## Hermetic

**Codec.** Round-trip properties for every primitive width (boundary-biased
generators — see [bsatn.md](bsatn.md)), plus example-based tests for the
error paths: `UnexpectedEnd`, `InvalidBool`, `InvalidUtf8`,
`UnknownVariant`, trailing bytes under `run_exact`, and `decode_rows`
reporting the failing index.

**Protocol.** Hex fixtures for frames: a hand-assembled `InitialConnection`
under each compression tag (compress the fixture in the test with the same
library you decode with), a `SubscribeApplied` with a `FixedSize` row list
and one with `RowOffsets`, a `TransactionUpdate` with paired
inserts/deletes and an event table, a `ReducerResult` in all four outcomes
including `Ok` with an **empty** `ret_value`, a `ProcedureResult` (to pin the
odd field order), an `OneOffQueryResult` ok and err, an unknown tag decoding
to `Unhandled`. On the encode side, byte-exact expectations for each client
message — including `CallReducer` with empty args (`00 00 00 00`).

**Client without a socket.** This is where designing the state transitions
as pure functions pays off ([client.md](client.md)):

- URL assembly: host/port, secure, base URI with and without a path prefix,
  trailing slashes trimmed, `ws://` rewritten, subprotocol header present,
  `Authorization` absent for anonymous and present with `with_token`, every
  compression spelling, `confirmed` absent by default and `true`/`false`
  when asked.
- Call correlation: `allocate_call` hands out ids and frames; `apply_reply`
  runs the right continuation for `Ok`, `OkEmpty`, `Err`, `InternalError`,
  an undecodable payload, and a reply of the *wrong kind* for the id;
  unmatched ids become events; `drain_pending` fails everything in flight.
- Dispatch: drive `apply_server_msg` with a builder's registered dispatchers
  and assert a `ReducerResult`'s rows reach `on_change` and a
  `ProcedureResult`'s / `OneOffQueryResult`'s do not; a `Changed` with an
  undecodable delete emits `RowDecodeFailed` and *no* partial `on_change`.
- Token: the greeting's token replaces the supplied one; the connect request
  built after `learn_token` carries it.
- Subscription list: builder subs seed ids 1..n; runtime add appends n+1;
  unsubscribe removes; ids are never reused; unknown id is a no-op.

**Failure paths that need a socket but not a server.** Point the client at a
**closed port**: with `NoReconnect`, `start` returns `HandshakeFailed`; with
reconnect, `start` succeeds and a `Reconnecting(1, initial_delay)` event
follows; `stop` is idempotent. Expect connection-refused noise in the test
log and say so in the README.

**Goldens and generated-type round-trips.** See [codegen.md](codegen.md).

## The live suite

Opt in with an environment variable (`SPACETIMEDB_INTEGRATION=1`); the
checks are no-ops without it so the ordinary test command stays hermetic.
Name them so the framework's auto-discovery **doesn't** pick them up (the
reference uses `*_check` instead of `*_test` and hands them to the runner
explicitly) — otherwise they show up in the hermetic count even when
skipped, and the framework's default per-test timeout kills the first,
module-compiling run.

### The fixture module

Deliberately tiny and covering exactly the shapes the checks need:

```rust
#[spacetimedb::table(accessor = widget, public)]
pub struct Widget { #[primary_key] #[auto_inc] pub id: u64, pub name: String, pub quantity: u32 }

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) { ctx.db.widget().insert(Widget { id: 0, name: "seed".into(), quantity: 1 }); }

#[spacetimedb::reducer]
pub fn add_widget(ctx: &ReducerContext, name: String, quantity: u32) { ctx.db.widget().insert(Widget { id: 0, name, quantity }); }
```

One public table with mixed column widths, one client-callable reducer that
inserts, one private `init` that seeds a row so a subscription has something
to deliver the moment it is applied — and so `init` exercises the
"drop `Private` callables silently" rule in codegen. It is the input to the
live golden, so changing it means regenerating.

### The harness

A shell script with three modes, run from the test process:

- **`serve`** — build the module, start a standalone server on a **free
  port** with a **throwaway data directory and CLI root** (so the user's own
  `~/.spacetime` login is never touched), publish, print one `READY <port>
  <database> <root>` line, then **block reading stdin**.

  ```sh
  spacetime --root-dir "$root" start --listen-addr 127.0.0.1:$port --data-dir "$data" --in-memory --non-interactive &
  # poll GET /v1/ping until it answers, then:
  spacetime --root-dir "$root" publish --server http://127.0.0.1:$port --bin-path "$wasm" --yes "$database"
  ```

  Run it as a **port program / child process whose stdin is a pipe from the
  test VM**. When the tests end — cleanly, by crash, or by the VM being
  killed — the pipe closes, `read` returns EOF, and an `EXIT` trap kills the
  server and removes the temp dir. Teardown is therefore not something a
  test has to remember. Trap `INT TERM HUP PIPE` into `exit` so a SIGPIPE on
  the `READY` echo (VM already gone) still runs the trap instead of stranding
  a server. Build *before* starting the server: the first build can take
  minutes and a failure mid-way would otherwise leave one running.

- **`describe <root> <port> <db>`** — `spacetime describe --json`, with
  stderr captured and only released if the command fails (the unconditional
  "UNSTABLE" warning would otherwise land in the JSON).

- **`regenerate [out]`** — boot exactly as `serve`, pipe `describe` through
  the generator into the live golden, tear down. This is how that golden is
  refreshed after an intentional generator or fixture change.

Own the child process from **one long-lived helper**, not from individual
tests: test frameworks typically run each test in a fresh process/context and
a child tied to it dies when the test returns. One server is shared by the
run.

### A TCP proxy for cutting live connections

To test "a dropped connection comes back subscribed as the same identity",
you need a drop. Reaching into the client and killing its socket object
tests the client's reaction to a message *you* sent; the failure that
matters (the socket's death propagating to the owner) only happens when a
connection really goes away. So: a throwaway TCP proxy the test points the
client at, forwarding bytes both ways, with `cut()` closing every connection
it carries while staying open for the reconnect, and `connections()` to
assert the reconnect actually made a second trip. Make `cut` wait for the
forwarding tasks to die before returning so the test isn't racing teardown.

### The checks, in order

Order matters because some insert rows and earlier ones assert the table
holds only the seed.

1. **Subscription delivers the seeded row** — `Connected`, then
   `InitialRows("widget", [seed])`.
2. **`describe` returns the published schema** — pins the seam so a broken
   describe fails as itself, not as a downstream parse error.
3. **A stored token comes back as the same identity** — connect anonymous,
   read the token, stop, connect again `with_token`, compare identities.
4. **`confirmed=false` is accepted and rows still arrive.**
5. **A one-off query reads rows without subscribing** — and a bad query is a
   `Rejected`, not an error.
6. **A dropped connection comes back with its subscriptions** — via the
   proxy: `Disconnected`, `Reconnecting(1)`, `Connected` with the *same*
   identity, the seed row again, proxy connection count 2, no errors. This
   is the check that dies with an unhandled socket exit if the owner is
   linked to the socket.
7. **End to end** — regenerate from the live schema, assert the committed
   golden is identical, then use the committed module to `subscribe_query`,
   call `add_widget`, see the insert arrive on `on_change` **before**
   `on_result`, and get `Returned(unit)` back (not `ReturnedNothing` — a
   unit-returning reducer sends an empty `Ok` payload).
8. **Runtime subscribe and unsubscribe** — add a subscription to a running
   client, drop it, get `Unsubscribed(id)`, show an insert the subscription
   would have reported arrives nowhere while the reducer still answers, then
   subscribe again and find the row you weren't told about. The drop is the
   half nothing hermetic can check: a client that has stopped being sent
   rows looks exactly like one whose rows haven't changed.

### Toolchain note

The live suite needs the `spacetime` CLI and whatever builds the fixture
module (a Rust toolchain with `wasm32-unknown-unknown` std and an `lld` that
can link wasm). Keep that toolchain **out of the default dev shell** so CI —
which only runs the hermetic suite — doesn't carry a compiler in its cache,
and have the harness say so explicitly when it can't find `cargo`.
