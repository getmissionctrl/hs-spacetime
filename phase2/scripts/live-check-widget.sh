#!/usr/bin/env bash
#
# Milestone M-C: publish the Haskell-authored `widget` module (primary key +
# auto-inc + `init` lifecycle reducer) to a REAL local SpacetimeDB and prove the
# auto-increment sequence and lifecycle reducer work:
#   - `init` runs on publish, seeding one row (id auto-assigned to 1),
#   - add_widget("a",10) and add_widget("b",20) get ids 2 and 3,
#   - SELECT id ORDER BY id yields exactly "1 2 3" (auto-inc + unique PK).
#
# Run inside `.#wasm`:  nix develop .#wasm --command bash -c 'phase2/scripts/live-check-widget.sh'
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
WASM="$root/server/example/widget-module.nowasi.wasm"
DB="widget-hs"

[ -f "$WASM" ] || { echo "FAIL: $WASM not found (build-module.sh widget-module-example + stub-wasi.sh)" >&2; exit 1; }

ROOT="$(mktemp -d)"
export HOME="$ROOT/home"
mkdir -p "$HOME" "$ROOT/data"
SRVPID=""
teardown() { [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true; rm -rf "$ROOT" || true; }
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
  for _ in $(seq 1 300); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    sleep 0.2
  done
  return 1
}

PORT="$(pick_port)"
URL="http://127.0.0.1:$PORT"
echo "== booting local SpacetimeDB on $URL =="
spacetime start --listen-addr "127.0.0.1:$PORT" --data-dir "$ROOT/data" --in-memory --non-interactive >"$ROOT/server.log" 2>&1 &
SRVPID=$!
wait_ready "$PORT" || { echo "server did not come up" >&2; cat "$ROOT/server.log" >&2; exit 1; }

echo "== publish widget-hs (runs init) =="
ok=
for _ in $(seq 1 20); do
  if spacetime publish "$DB" -b "$WASM" -s "$URL" --anonymous --yes; then ok=1; break; fi
  sleep 0.5
done
[ -n "$ok" ] || { echo "FAIL: publish rejected" >&2; cat "$ROOT/server.log" >&2; exit 1; }

count() { spacetime sql --server "$URL" --anonymous "$DB" 'SELECT COUNT(*) AS n FROM widget' | grep -oE '[0-9]+' | tail -1; }

echo "== after publish, init should have seeded 1 row =="
c0="$(count)"; echo "count=$c0"
[ "${c0:-0}" = "1" ] || { echo "FAIL: init did not seed exactly 1 row (got ${c0:-none})" >&2; tail -40 "$ROOT/server.log" >&2; exit 1; }

echo "== add_widget(\"a\",10), add_widget(\"b\",20) =="
spacetime call --server "$URL" --anonymous "$DB" add_widget '"a"' '10'
spacetime call --server "$URL" --anonymous "$DB" add_widget '"b"' '20'

echo "== SELECT id FROM widget (expect ids 1 2 3, sorted client-side) =="
ids="$(spacetime sql --server "$URL" --anonymous "$DB" 'SELECT id FROM widget' | grep -oE '^[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -n | tr '\n' ' ' | sed 's/ *$//')"
echo "ids=[$ids]"
if [ "$ids" = "1 2 3" ]; then
  echo "GO: auto-increment assigned distinct ids 1 2 3"
else
  echo "FAIL: expected ids '1 2 3', got '$ids'" >&2
  spacetime sql --server "$URL" --anonymous "$DB" 'SELECT * FROM widget ORDER BY id' >&2
  exit 1
fi

echo "== scan server log for traps =="
if grep -Ei 'trap|panic|unreachable|energy|abort' "$ROOT/server.log"; then
  echo "WARN: trap-like lines above"
else
  echo "OK: no trap-like lines"
fi
echo "== ALL CHECKS PASSED — GO (M-C) =="
