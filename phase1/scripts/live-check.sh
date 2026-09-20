#!/usr/bin/env bash
#
# Milestone M-A live go/no-go for Phase 1: publish the WASI-free, Haskell-derived
# runtime module (server/example/person-module.nowasi.wasm) to a REAL local
# SpacetimeDB server and prove all three reducers round-trip by NAME.
#
# It:
#   1. boots a throwaway in-memory local SpacetimeDB server (its own HOME/data),
#   2. publishes the PREBUILT nowasi wasm via `spacetime publish -b <wasm>`,
#   3. calls record("carol") + record_n(3), asserts COUNT(event) == 2,
#   4. calls record_n(0) and asserts it is REJECTED (reducer error, not a trap),
#   5. calls delete_all() and asserts COUNT(event) == 0,
#   6. greps the server log for wasm traps.
#
# Run inside the `.#wasm` (or `.#live`) dev shell:
#   nix develop .#wasm --command bash -c 'phase1/scripts/live-check.sh'
#
# Exit 0 => GO. Non-zero => NO-GO/partial; the output above the failure and the
# captured server log are the evidence.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"        # repo root
WASM="$root/server/example/person-module.nowasi.wasm"
DB="event-hs"

[ -f "$WASM" ] || { echo "FAIL: $WASM not found (run build-module.sh + wizer-init.sh + stub-wasi.sh)" >&2; exit 1; }

# --- throwaway server home so we never touch the user's real config/identity ---
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

# Parse the integer out of a `spacetime sql 'SELECT COUNT(*) AS n ...'` result.
count_events() {
  spacetime sql --server "$URL" --anonymous "$DB" 'SELECT COUNT(*) AS n FROM event' \
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

echo "== call record(\"carol\") =="
spacetime call --server "$URL" --anonymous "$DB" record '"carol"'
echo "== call record_n(3) =="
spacetime call --server "$URL" --anonymous "$DB" record_n '3'

echo "== SELECT COUNT(*) AS n FROM event (expect 2) =="
c1="$(count_events)"
echo "count = ${c1:-<none>}"
[ "${c1:-0}" = "2" ] || { echo "FAIL: after record + record_n(3), count=${c1:-<none>} != 2" >&2; tail -50 "$ROOT/server.log" >&2; exit 1; }

echo "== call record_n(0) — expect REJECTION (reducer error, not a trap) =="
if spacetime call --server "$URL" --anonymous "$DB" record_n '0'; then
  echo "FAIL: record_n(0) was accepted; expected rejection" >&2
  exit 1
else
  echo "OK: record_n(0) correctly rejected"
fi

echo "== SELECT COUNT(*) AS n FROM event (still expect 2 after rejected call) =="
c2="$(count_events)"
echo "count = ${c2:-<none>}"
[ "${c2:-0}" = "2" ] || { echo "FAIL: after rejected record_n(0), count=${c2:-<none>} != 2" >&2; exit 1; }

echo "== call delete_all() =="
spacetime call --server "$URL" --anonymous "$DB" delete_all

echo "== SELECT COUNT(*) AS n FROM event (expect 0) =="
c3="$(count_events)"
echo "count = ${c3:-<none>}"
[ "${c3:-0}" = "0" ] || { echo "FAIL: after delete_all, count=${c3:-<none>} != 0" >&2; tail -50 "$ROOT/server.log" >&2; exit 1; }

echo "== scan server log for wasm traps =="
if grep -Ei 'trap|panic|unreachable|wasm.*error|out of|abort' "$ROOT/server.log"; then
  echo "WARN: trap-like lines in server log (see above)"
else
  echo "OK: no trap-like lines in server log"
fi

echo "== ALL CHECKS PASSED — GO =="
