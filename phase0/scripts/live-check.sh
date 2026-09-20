#!/usr/bin/env bash
#
# Milestone M-A live go/no-go: publish the WASI-free, Haskell-derived module
# (phase0/module/person-module.nowasi.wasm) to a REAL local SpacetimeDB server
# and prove a reducer round-trips.
#
# This is the culminating Phase 0 check. It:
#   1. boots a throwaway in-memory local SpacetimeDB server (its own HOME/data),
#   2. publishes the PREBUILT nowasi wasm via `spacetime publish -b <wasm>`
#      (NO rebuild from a Rust project),
#   3. calls the `add` reducer, SELECTs the row back,
#   4. calls `add` ~20 more times and asserts the row count,
#   5. greps the server log for wasm traps.
#
# Run inside the `.#wasm` (or `.#live`) dev shell:
#   nix develop .#wasm --command bash -c 'phase0/scripts/live-check.sh'
#
# Exit 0 => GO for the criteria this script exercises. Non-zero => NO-GO/partial;
# the captured server log + command output above the failure is the evidence.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"          # phase0/
WASM="$root/module/person-module.nowasi.wasm"
DB="person-hs"
N=20                                              # extra reducer calls

[ -f "$WASM" ] || { echo "FAIL: $WASM not found (run stub-wasi.sh)" >&2; exit 1; }

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

# ---------------------------------------------------------------------------
# 1+2. PUBLISH the prebuilt nowasi wasm. -b/--bin-path publishes an already-built
#      binary instead of building a project. --anonymous + --yes keep it
#      non-interactive (no login prompt, no remote/migrate/destroy prompts).
# ---------------------------------------------------------------------------
echo "== publish (spacetime publish -b nowasi.wasm) =="
ok=
for _ in $(seq 1 20); do
  if spacetime publish "$DB" -b "$WASM" -s "$URL" --anonymous --yes; then ok=1; break; fi
  sleep 0.5
done
[ -n "$ok" ] || { echo "FAIL: publish rejected; server log:" >&2; cat "$ROOT/server.log" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 3. CALL add("carol"). The CLI JSON-encodes the arg into the BSATN {name}
#    product; our module decodes it.
# ---------------------------------------------------------------------------
echo "== call add(\"carol\") =="
spacetime call --server "$URL" --anonymous "$DB" add '"carol"'

echo "== SELECT * FROM person =="
spacetime sql --server "$URL" --anonymous "$DB" 'SELECT * FROM person'

# ---------------------------------------------------------------------------
# 4. REENTRANCY: call add N more times with distinct names.
# ---------------------------------------------------------------------------
echo "== reentrancy: $N more add() calls =="
for i in $(seq 1 "$N"); do
  spacetime call --server "$URL" --anonymous "$DB" add "\"person-$i\"" >/dev/null
done

echo "== SELECT COUNT(*) AS n FROM person (expect $((N + 1))) =="
# SpacetimeDB SQL requires aggregate expressions to carry a column alias.
count_out="$(spacetime sql --server "$URL" --anonymous "$DB" 'SELECT COUNT(*) AS n FROM person')"
echo "$count_out"
# Parse the integer out of the sql table output (last all-digit token).
count="$(echo "$count_out" | grep -oE '[0-9]+' | tail -1)"
expected=$((N + 1))

echo "== scan server log for wasm traps =="
if grep -Ei 'trap|panic|unreachable|wasm.*error|out of|abort' "$ROOT/server.log"; then
  echo "WARN: trap-like lines in server log (see above)"
else
  echo "OK: no trap-like lines in server log"
fi

if [ "${count:-0}" = "$expected" ]; then
  echo "GO: row count $count == expected $expected"
else
  echo "FAIL: row count ${count:-<none>} != expected $expected" >&2
  echo "--- server log tail ---" >&2
  tail -50 "$ROOT/server.log" >&2
  exit 1
fi

echo "== ALL CHECKS PASSED — GO =="
