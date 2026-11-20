# backend/ — Elixir service
Owned by the **backend** agent; integrations owns the external client modules. See the root CLAUDE.md and docs/ARCHITECTURE.md.

## Run and test (added Week 2, B1/B2)
- Dev: `cd backend && mix run --no-halt` (port 47474, no token, warning logged). `QUICKSILVER_PORT=0` lets the OS pick; `QUICKSILVER_TOKEN=...` turns the hello token check on. Ctrl+D (stdin EOF) stops it; set `QUICKSILVER_EXIT_ON_STDIN_EOF=0` when running in the background.
- stdout carries only the `QUICKSILVER_READY` line (plus compile output in dev); all logs go to stderr.
- Tests: `mix test` (offline). `mix test --include e2e` also boots a real `mix run` subprocess.
- Layout: `Quicksilver.Gateway.*` = WebSocket gateway (routes in `Gateway.Routes`), `Quicksilver.Health` = per-source status API for integrations, `Quicksilver.Settings` = `settings.json`. Supervision tree and restart reasoning: `Quicksilver.Application` moduledoc.
