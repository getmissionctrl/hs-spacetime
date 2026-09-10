#!/usr/bin/env bash
#
# Live SpacetimeDB harness for the opt-in integration suite and for capturing
# schema fixtures. Runs inside the `.#live` dev shell (provides `spacetime`).
#
# Modes:
#   serve                       Build + start a throwaway in-memory server,
#                               publish the fixture module, print
#                               "READY <port> <db> <root>", then block on stdin.
#                               Closing stdin (EOF) tears everything down.
#   describe <port> <db>        Print `spacetime describe --json` for a running
#                               server (JSON on stdout, warnings on stderr).
#   capture <out.json>          Self-contained: boot, publish, describe to
#                               <out.json>, tear down.
#   regenerate <out.hs>         Self-contained: boot, publish, describe, pipe
#                               through hs-spacetime-codegen to <out.hs>.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$here/fixture"
DB="fixture"

pick_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(((RANDOM % 20000) + 20000))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      echo "$p"
      return 0
    fi
    exec 3>&- 3<&- 2>/dev/null || true
  done
  echo 3000
}

wait_ready() {
  local port="$1"
  for _ in $(seq 1 300); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# Boot a server + publish the fixture. Echos "<port> <root>". Sets a global
# SRVPID and registers cleanup via the caller's EXIT trap ($ROOT is exported).
boot() {
  ROOT="$(mktemp -d)"
  export HOME="$ROOT/home"
  mkdir -p "$HOME" "$ROOT/data"
  local port
  port="$(pick_port)"
  # Build first so a compile error fails loudly before the server starts.
  spacetime build -p "$FIXTURE" >&2
  spacetime start \
    --listen-addr "127.0.0.1:$port" \
    --data-dir "$ROOT/data" \
    --in-memory \
    --non-interactive >"$ROOT/server.log" 2>&1 &
  SRVPID=$!
  if ! wait_ready "$port"; then
    echo "server did not become ready; log:" >&2
    cat "$ROOT/server.log" >&2
    return 1
  fi
  # Publish (retry briefly while the server finishes coming up).
  local ok=
  for _ in $(seq 1 20); do
    if spacetime publish "$DB" -p "$FIXTURE" -s "http://127.0.0.1:$port" --anonymous -y >&2; then
      ok=1
      break
    fi
    sleep 0.5
  done
  [ -n "$ok" ] || { echo "publish failed" >&2; return 1; }
  echo "$port"
}

teardown() {
  [ -n "${SRVPID:-}" ] && kill "$SRVPID" 2>/dev/null || true
  [ -n "${SRVPID:-}" ] && wait "$SRVPID" 2>/dev/null || true
  [ -n "${ROOT:-}" ] && rm -rf "$ROOT" || true
}

describe_json() {
  local port="$1" db="$2"
  spacetime describe "$db" --json -s "http://127.0.0.1:$port" --anonymous
}

mode="${1:-}"
case "$mode" in
  serve)
    trap teardown EXIT
    trap 'exit' INT TERM HUP PIPE
    port="$(boot)"
    echo "READY $port $DB $ROOT"
    read -r _ || true
    ;;
  describe)
    describe_json "$2" "$3"
    ;;
  capture)
    out="${2:?usage: live-harness.sh capture <out.json>}"
    trap teardown EXIT
    trap 'exit' INT TERM HUP PIPE
    port="$(boot)"
    describe_json "$port" "$DB" >"$out"
    echo "wrote $out" >&2
    ;;
  regenerate)
    out="${2:?usage: live-harness.sh regenerate <out.hs>}"
    trap teardown EXIT
    trap 'exit' INT TERM HUP PIPE
    port="$(boot)"
    describe_json "$port" "$DB" | cabal run -v0 hs-spacetime-codegen -- "$out"
    echo "wrote $out" >&2
    ;;
  *)
    echo "usage: live-harness.sh {serve|describe <port> <db>|capture <out.json>|regenerate <out.hs>}" >&2
    exit 2
    ;;
esac
