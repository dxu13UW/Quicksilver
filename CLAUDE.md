# CLAUDE.md: Project memory for all agents

## Current phase
**Week 1: Scaffolding only. Do not write application code.** Planning, docs, and agent setup only.
Update this line when the phase changes (see `docs/PLAN.md`).

## What this project is
A Path of Exile 1 companion app with three parts:
- **Elixir backend** (`backend/`): a local service on `127.0.0.1`. It does all data fetching, caching, rate limiting, item parsing, pricing, and log-file watching.
- **C++ / Qt 6 frontend** (`frontend/`): two windows from one process.
  - The **command center** is a normal window.
  - The **overlay** is a transparent, always-on-top, click-through window over the game.
- **Shared contract** (`shared/`, `docs/PROTOCOL.md`): the only way the two sides talk.

## Golden rules
1. **The protocol is the boundary.**
   - The frontend never calls external APIs.
   - The backend never draws UI.
   - Any protocol change updates `docs/PROTOCOL.md` first, then both sides.
2. **Follow `docs/COMPLIANCE.md`.**
   - No reading game memory, no packet inspection, no input automation.
   - At most one game action per user keypress.
   - Violations are bugs of the highest severity.
3. **Respect rate limits.**
   - All external HTTP goes through the backend's rate-limited clients (`docs/DATA_SOURCES.md`).
   - Never add a direct HTTP call elsewhere.
4. **Do not copy PoE Overlay** (Kyusung Interactive).
   - Similar features are fine.
   - Their code, UI layout, icons, wording, and branding are not.
5. **Log every session.** Append to `LOG.md` using the template at its top before ending a session.
6. **Stay in your lane.**
   - Each subagent owns specific paths (see `.claude/agents/`).
   - If a change needs another lane, write a handoff note in `LOG.md` instead of editing their files.

## Tech decisions (see `docs/decisions/`)
- **Backend:** Elixir/OTP; local WebSocket server (ADR-002).
- **Frontend:** Qt 6, CMake, Windows 10/11 x64 (ADR-001).
- **Item input:** clipboard item text (Ctrl+C in game), parsed by the backend.
- **Trade and session events:** the backend tails the game's `Client.txt` log file.
- **Distribution:** Windows installer on GitHub Releases (ADR-003, not final).

## Where to look first
`docs/PLAN.md` → current week's work items → `LOG.md` (latest entry) → the doc for your area.
