# Plan

**Deadlines**
- Show and tell: Monday, Dec 7, in class.
- Final submission: Sunday, Dec 13, 11:59 PM.
- Portfolio link due at the end of every week.

Week dates below are my assumption. Adjust them if the course calendar differs.

Status key: ☐ not started · ◐ in progress · ☑ done · ✗ dropped

---

## Week 1 (Nov 9–15): Scaffold. No code.
- ☑ Repository structure, README, CLAUDE.md
- ☑ Subagent definitions (backend, frontend, integrations, QA, scribe)
- ☑ Architecture, protocol draft, data sources, compliance docs
- ☑ Resolve items in `OPEN_QUESTIONS.md` that block Week 2
- ☐ Collect 20+ sample item texts (Ctrl+C in game) into `shared/samples/`. These are test fixtures, not code.
- ☑ Install toolchains: Elixir/Erlang, Qt 6 + CMake + MSVC, Git (Qt 6.8.3 + VS 2022 Build Tools on 2026-11-19)
- ◐ Portfolio card placeholder updated, link submitted (card updated 2026-11-15; submit link)

## Week 2 (Nov 16–22): Walking skeleton + command center shell
Goal: both halves run and talk to each other, and the dashboard shows real data.

- ☑ **B1** Elixir app boots under a supervisor and serves a WebSocket on localhost
- ☑ **B2** Health/heartbeat messages per PROTOCOL.md
- ☑ **I1** poe.ninja client with cache and refresh schedule (currency + one item category)
- ☑ **I2** League list from the official API; league selection stored in backend config
- ☑ **F1** Qt app with command center window; connects to backend and shows connection status
- ☑ **F2** Dashboard: currency rates table, league selector, backend health panel
- ☑ **Q1** QA test plan for protocol messages; first backend tests
- ☑ Log entries and portfolio update (card drafted 2026-11-21; owner submits link)

## Week 3 (Nov 23–29): Item price check (Thanksgiving week, so plan light)
- ☐ **F3** Overlay window: transparent, always-on-top, click-through except on its own panel
- ☐ **F4** Global hotkey that copies the hovered item and sends the text to the backend
- ☐ **B3** Item text parser (rarity, base, mods, links, sockets, corruption) tested against `shared/samples/`
- ☐ **B4** Pricing per ADR-004: poe.ninja for everything it covers; trade API (on demand) for rares; `trade_api_enabled` kill switch with an "Open on trade site" fallback
- ☐ **I3** Trade API client that obeys rate-limit headers dynamically
- ☐ **F5** Price result panel in overlay; history list in command center
- ☐ **Q2** QA: parser fixtures, rate-limit behaviour, compliance review of hotkey flow

## Week 4 (Nov 30–Dec 6): Stash trade overlay + ship v0.1
- ☐ **B5** Client.txt tailer; parse incoming trade whispers (item, price, stash tab, position)
- ☐ **F6** Trade overlay: incoming request list, stash-cell highlight, quick-reply buttons
- ☐ **B6** Package the Elixir release so it runs without the user installing Elixir
- ☐ **F7** Windows installer wizard (`Quicksilver-Setup.exe`) bundling the Qt client and the backend release
  - Wizard pages: Welcome → License → "Not affiliated with Grinding Gear Games" notice (COMPLIANCE.md) → Install folder → Shortcuts (Start Menu, optional desktop) → Install → Finish with a "Launch Quicksilver" checkbox
  - Registers an uninstaller in Windows "Apps & features"; uninstall removes everything except the user's settings, unless they choose to remove those too
  - Tool decided in ADR-003 (Inno Setup and WiX both produce this wizard)
- ☐ Publish **v0.1** on GitHub Releases with the installer attached
- ☐ **Q3** QA: install on a clean machine or VM; end-to-end smoke test
- ☐ Demo script and recording for show and tell

## Dec 7–13: Show, then finish
- ☐ Show and tell (Dec 7)
- ☐ **B7/F8** Session summary: maps run and time per zone from Client.txt
- ☐ Fix issues found at the demo; publish v0.2 if possible
- ☐ Final portfolio card: title, link, reflection

## Stretch (only if ahead)
- Official OAuth app for stash access → stash valuation and currency-earned tracking
- More data sources (see DATA_SOURCES.md)
- Settings UI for hotkeys and overlay position
