#!/usr/bin/env bash
#
# Automated UI end-to-end: publish the Haskell chat wasm to a local SpacetimeDB
# server on port 3000, then run the React client's integration test
# (src/App.integration.test.tsx), which connects over WebSocket and drives the
# full chat flow: connect -> client_connected creates the user -> set_name -> the
# name renders -> send_message -> the message renders.
#
# The test hardcodes ws://localhost:3000 / db `quickstart-chat`, so the server
# MUST listen on 3000. Run inside `.#live`. Requires the wasm built first
# (examples/quickstart-chat/server/scripts/build-wasm.sh). Exit 0 => GO.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
WASM="$root/examples/quickstart-chat/server/dist/chat-module.nowasi.wasm"
CLIENT="$root/examples/quickstart-chat/client-web"
DB="quickstart-chat"
PORT=3000
URL="http://127.0.0.1:$PORT"

[ -f "$WASM" ] || { echo "FAIL: $WASM not found (run server/scripts/build-wasm.sh)" >&2; exit 1; }

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

wait_ready() {
  for _ in $(seq 1 300); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    sleep 0.2
  done
  return 1
}

echo "== booting local SpacetimeDB on $URL (data in $ROOT) =="
spacetime start \
  --listen-addr "127.0.0.1:$PORT" \
  --data-dir "$ROOT/data" \
  --in-memory \
  --non-interactive >"$ROOT/server.log" 2>&1 &
SRVPID=$!
wait_ready || { echo "server did not come up; log:" >&2; cat "$ROOT/server.log" >&2; exit 1; }

echo "== publish $DB (spacetime publish -b nowasi.wasm) =="
ok=
for _ in $(seq 1 20); do
  if spacetime publish "$DB" -b "$WASM" -s "$URL" --anonymous --yes; then ok=1; break; fi
  sleep 0.5
done
[ -n "$ok" ] || { echo "FAIL: publish rejected; server log:" >&2; cat "$ROOT/server.log" >&2; exit 1; }

echo "== run the client integration test (vitest) against the live module =="
( cd "$CLIENT" && npm test )
rc=$?

echo "== reducer / error lines from server log =="
grep -iE 'set_name|send_message|client_connected|client_disconnected|reducer|error|empty|unknown user|panic|trap' "$ROOT/server.log" | tail -60 || echo "(none)"

echo "== scan server log for wasm traps =="
if grep -Ei 'trap|panic|unreachable|wasm.*error|out of|abort' "$ROOT/server.log"; then
  echo "WARN: trap-like lines in server log (see above)"
else
  echo "OK: no trap-like lines in server log"
fi

[ "$rc" -eq 0 ] || { echo "FAIL: client integration test failed (rc=$rc)" >&2; exit "$rc"; }
echo "== UI E2E PASSED — GO =="
