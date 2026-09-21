# quickstart-chat — Haskell TUI client

A terminal chat client (Brick) that connects to the Haskell `quickstart-chat`
module and reuses its typed handles (`Chat.app`), so reducer/table calls are
checked against the schema at compile time.

## Run

Publish the module and start SpacetimeDB on `127.0.0.1:3000` (see
[`../README.md`](../README.md)), then in the `.#dev` shell:

    STDB_HOST=127.0.0.1 STDB_PORT=3000 STDB_DB=quickstart-chat \
      cabal run chat-tui:exe:chat-tui

Environment variables (all optional): `STDB_HOST` (default `127.0.0.1`),
`STDB_PORT` (default `3000`), `STDB_DB` (default `quickstart-chat`).

## Keys

- Type a line, press **Enter** to send a message.
- `/name alice` + **Enter** sets your display name.
- **Esc** or **Ctrl-C** quits.
