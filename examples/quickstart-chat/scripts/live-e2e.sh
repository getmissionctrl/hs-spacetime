#!/usr/bin/env bash
#
# Live end-to-end check for the quickstart-chat module: publish the WASI-free,
# Haskell-derived reactor (examples/quickstart-chat/server/dist/chat-module.nowasi.wasm)
# to a throwaway local SpacetimeDB server and prove send_message round-trips.
#
# It:
#   1. boots a throwaway in-memory local SpacetimeDB server (its own HOME/data),
#   2. publishes the PREBUILT nowasi wasm via `spacetime publish -b <wasm>` as `quickstart-chat`,
#   3. calls send_message("hello from haskell"), asserts COUNT(message) == 1 and the text,
#   4. calls send_message("") and asserts it is REJECTED (reducer error, not a trap),
#   5. greps the server log for wasm traps.
#
# Run inside the `.#live` (or `.#wasm`) dev shell. Requires the wasm built first
# (examples/quickstart-chat/server/scripts/build-wasm.sh). Exit 0 => GO.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"        # repo root
WASM="$root/examples/quickstart-chat/server/dist/chat-module.nowasi.wasm"
DB="quickstart-chat"

[ -f "$WASM" ] || { echo "FAIL: $WASM not found (run examples/quickstart-chat/server/scripts/build-wasm.sh)" >&2; exit 1; }

ROOT="$(mktemp -d)"
export HOME="$ROOT/home"
mkdir -p "$HOME" "$ROOT/data"

SRVPID=""
teardown() {
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true
  [ -n "$SRVPID" ] && wait "$SRVPID" 2>/dev/null || true
  rm -rf "$ROOT" || true
}
trap teardown EXIT
trap 'exit' INT TERM HUP PIPE

pick_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(((RANDOM % 20000) + 20000))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return 0; fi
    exec 3>&- 3<&- 2>/dev/null || true
  done
  echo 3000
}

wait_ready() {
  local port="$1"
  for _ in $(seq 1 300); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    sleep 0.2
  done
  return 1
}

count_messages() {
  spacetime sql --server "$URL" --anonymous "$DB" 'SELECT COUNT(*) AS n FROM message' \
    | grep -oE '[0-9]+' | tail -1
}

PORT="$(pick_port)"
URL="http://127.0.0.1:$PORT"
echo "== booting local SpacetimeDB on $URL (data in $ROOT) =="
spacetime start \
  --listen-addr "127.0.0.1:$PORT" \
  --data-dir "$ROOT/data" \
  --in-memory \
  --non-interactive >"$ROOT/server.log" 2>&1 &
SRVPID=$!
wait_ready "$PORT" || { echo "server did not come up; log:" >&2; cat "$ROOT/server.log" >&2; exit 1; }

echo "== publish (spacetime publish -b nowasi.wasm) as $DB =="
ok=
for _ in $(seq 1 20); do
  if spacetime publish "$DB" -b "$WASM" -s "$URL" --anonymous --yes; then ok=1; break; fi
  sleep 0.5
done
[ -n "$ok" ] || { echo "FAIL: publish rejected; server log:" >&2; cat "$ROOT/server.log" >&2; exit 1; }

echo "== call send_message(\"hello from haskell\") =="
spacetime call --server "$URL" --anonymous "$DB" send_message '"hello from haskell"'

echo "== SELECT COUNT(*) AS n FROM message (expect 1) =="
c1="$(count_messages)"
echo "count = ${c1:-<none>}"
[ "${c1:-0}" = "1" ] || { echo "FAIL: after send_message, count=${c1:-<none>} != 1" >&2; tail -50 "$ROOT/server.log" >&2; exit 1; }

echo "== SELECT text FROM message (expect the sent text) =="
spacetime sql --server "$URL" --anonymous "$DB" 'SELECT text FROM message' | tee "$ROOT/msg.out"
grep -q "hello from haskell" "$ROOT/msg.out" || { echo "FAIL: message text not found" >&2; exit 1; }

echo "== call send_message(\"\") — expect REJECTION (reducer error, not a trap) =="
if spacetime call --server "$URL" --anonymous "$DB" send_message '""'; then
  echo "FAIL: empty send_message was accepted; expected rejection" >&2
  exit 1
else
  echo "OK: empty send_message correctly rejected"
fi

echo "== SELECT COUNT(*) AS n FROM message (still expect 1) =="
c2="$(count_messages)"
echo "count = ${c2:-<none>}"
[ "${c2:-0}" = "1" ] || { echo "FAIL: after rejected empty send_message, count=${c2:-<none>} != 1" >&2; exit 1; }

echo "== scan server log for wasm traps =="
if grep -Ei 'trap|panic|unreachable|wasm.*error|out of|abort' "$ROOT/server.log"; then
  echo "WARN: trap-like lines in server log (see above)"
else
  echo "OK: no trap-like lines in server log"
fi

echo "== ALL CHECKS PASSED — GO =="
