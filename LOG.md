# Project log

Newest entries at the bottom. Every agent session ends with an entry. This log is how the next session (human or agent) picks up.

## Entry template
```
### YYYY-MM-DD: <short title>
- Who: me / <agent name>
- Goal:
- Done:
- Decisions: (link ADR if any)
- Problems / surprises:
- Handoffs: (to which agent, what)
- Next step:
```

---

### 2026-11-15: Week 1 scaffold
- Who: me + Claude (chat)
- Goal: set up structure and planning before any code, per the instructor's Week 1 guidance.
- Done: repo layout, README, CLAUDE.md, PLAN, ARCHITECTURE, PROTOCOL v0, DATA_SOURCES, COMPLIANCE, ADR-001/002/003, five subagent definitions.
- Decisions:
  - Solo project.
  - MVP priority: dashboard > price check > stash trade overlay > session summary.
  - Qt 6 frontend (ADR-001); local WebSocket (ADR-002).
  - Stash trade overlay will use Client.txt whispers, so no OAuth is needed for the MVP.
- Problems / surprises: starting late in the week.
- Handoffs: none yet.
- Next step: answer OPEN_QUESTIONS blockers, collect item text samples, install toolchains.

### 2026-11-15: Resolve Week 2 blockers (moved to Claude Code)
- Who: me + Claude Code
- Goal: pick up from the desktop chat session and clear the questions that block Week 2.
- Done:
  - Removed 22 Windows `Zone.Identifier` files.
  - Resolved OPEN_QUESTIONS #2–5 and recorded them in ADR-001, ADR-002, ARCHITECTURE and DATA_SOURCES.
- Decisions:
  - Client.txt: support both Steam and standalone, auto-detect the path, override in settings.
  - Backend: a single Mix app with Bandit + WebSock, no Phoenix and no umbrella; chosen for the least overhead (ADR-002).
  - UI: Qt Widgets (ADR-001).
  - Repo: public on GitHub.
  - Published the repo at https://github.com/dxu13UW/Quicksilver (HTTPS remote; SSH key belongs to a different account).
  - Plan: F7 is now a full Windows setup wizard (pages listed in docs/PLAN.md); publishing v0.1 is its own item. Noted in ADR-003.
  - Name: **Quicksilver** (OPEN_QUESTIONS #1). Code names: `:quicksilver` / `Quicksilver` / `Quicksilver.exe`.
- Problems / surprises:
  - Root `PLAN.md` was an exact duplicate of `docs/PLAN.md`. Deleted it and pointed the qa/scribe agents at `docs/PLAN.md`.
  - The folder wasn't a git repo. Ran `git init` (branch `main`), added `.gitignore`, made the first commit.
- Handoffs: none.
- Next step:
  - Collect 20+ item text samples into `shared/samples/`.
  - Install Qt 6 + MSVC on Windows (WSL already has Elixir 1.18.3 / OTP 27).

### 2026-11-15: Requirements doc draft
- Who: me + Claude Code
- Goal: define testable "done" criteria. Decided against a full SRS because the existing docs already cover most of it.
- Done:
  - Drafted `docs/REQUIREMENTS.md` v0.1: functional requirements (CON, DASH, PC, TR, SES, INS) with priorities, PLAN IDs and acceptance checks, plus non-functional requirements (performance, reliability, API, compliance/security, UX, maintainability).
  - Linked it from the README. The qa agent now checks requirement IDs, and test cases must name the requirement they verify.
  - Verified the APIs live. poe.ninja's old `/api/data/*` endpoints return 404; the new ones are `/poe1/api/...`. Trade search limits come from `x-rate-limit-ip` headers.
- Decisions: lightweight REQUIREMENTS.md instead of an IEEE-style SRS.
- Problems / surprises: DATA_SOURCES.md still lists the old poe.ninja endpoints.
- Handoffs: integrations, to record the verified endpoints and rate-limit headers in DATA_SOURCES.md. **Done 2026-11-15** (see "DATA_SOURCES endpoint verification" below).
- Next step:
  - Review the *(target)* numbers in REQUIREMENTS.md.
  - Collect item samples.
  - Install Qt and MSVC.

### 2026-11-15: DATA_SOURCES endpoint verification
- Who: integrations agent
- Goal: record the live-verified endpoints, rate-limit headers and cache TTLs in `docs/DATA_SOURCES.md` (handoff from "Requirements doc draft").
- Done:
  - Re-checked every endpoint with about 30 light requests (generic User-Agent, one trade search, one fetch, no 429s).
  - Rewrote the source table. Added "Rules for every client" (User-Agent, how to read rate-limit headers, 429/`Retry-After`), per-source "Endpoints (verified 2026-11-15)", a caching table with an explicit TTL for every cache, and a behaviour-changes log.
- Decisions:
  - poe.ninja TTL = `Cache-Control` max-age, with a 30 min fallback when the header is missing or `no-cache`.
  - Trade league list is the primary source; legacy `/leagues` is the fallback.
  - All URLs live in one module.
- Problems / surprises:
  - poe.ninja: divination cards and fragments moved from the item overview to the exchange endpoint.
  - poe.ninja: an unknown exchange type returns 200 with empty data, and so did `Scarab`.
  - poe.ninja: `Essence` is sent with `no-cache`.
  - Trade fetch has its own rate-limit policy (`trade-fetch-request-limit`).
  - The documented `GET /league` needs OAuth (401).
  - GGG docs say only endpoints in their API reference are supported, and that reverse-engineering others breaks the ToU (section 7i). The trade endpoints are not in the reference.
- Handoffs:
  - Owner: decide whether the trade-API ToU risk is acceptable. If so, record it in COMPLIANCE.md (not my lane).
  - Owner: choose the User-Agent contact value.
- Next step: Week 2. Build the URL module and clients, and record fixtures from these endpoints for tests.

### 2026-11-15: Pricing source split (ADR-004)
- Who: me + Claude Code
- Goal: decide how to handle the trade-API ToU risk the integrations agent flagged.
- Done:
  - Checked GGG's developer docs directly. Confirmed the "only our API Reference is supported / ToU 7i" wording. Also found the official overlay and macro rules, the exact third-party notice, the invalid-request (4xx) threshold, and that GGG isn't accepting new app registrations.
  - Wrote ADR-004 and rewrote COMPLIANCE.md with quotes from GGG's docs and the accepted risk.
  - Updated REQUIREMENTS (PC-3, PC-4 now Must, new PC-8 kill switch, PC-9, NFR-API-4), OPEN_QUESTIONS #7, PLAN B4, CLAUDE.md, and the DATA_SOURCES compliance note.
  - Added notices to the README.
- Decisions: use both sources. poe.ninja first; the trade API only for rares and unmatched items, only on demand, behind the `trade_api_enabled` kill switch with an "Open on trade site" fallback (ADR-004).
- Problems / surprises: the integrations handoffs are both done. Trade-API risk: accepted. User-Agent contact: the repo URL, `https://github.com/dxu13UW/Quicksilver`.
- Handoffs: none.
- Next step:
  - Collect item samples.
  - Install Qt and MSVC.

### 2026-11-19: B1 + B2 backend walking skeleton
- Who: backend agent
- Goal: first application code. Mix app with a supervision tree, `/ws` gateway with the v1 handshake and envelope, the `health` push, settings file (PLAN B1, B2).
- Done:
  - Mix project in `backend/` (`:quicksilver`, Bandit + WebSockAdapter + Jason; `mint_web_socket` test-only). No HTTP client and no external-API code.
  - Supervision tree (`Quicksilver.Application` moduledoc explains each restart strategy): `Quicksilver.Supervisor` one_for_one → `Settings` (permanent) → `Health` (permanent) → `Gateway.Endpoint` (Bandit on 127.0.0.1, permanent; connections are temporary, one process each) → `StdinWatcher` (transient; off in tests and IEx).
  - Launch per PROTOCOL: `QUICKSILVER_PORT` (default 47474, 0 = OS picks), `QUICKSILVER_TOKEN` (unset = check off + warning), exactly one `QUICKSILVER_READY {"port":N,"protocol_version":1}` line with the real port, exit on stdin EOF. Logs go to stderr so stdout stays clean.
  - Gateway: envelope (`ts` UTC ms + Z, unknown fields ignored), hello within 5 s, token check (constant time), `protocol_mismatch` with `expected`, `unauthorized` before hello / on timeout, `bad_json`, `bad_request`, `unknown_type` (stays open), `internal` for handler crashes (stays open). Routing seam: `Gateway.Routes` (type → `Gateway.Handler` module).
  - `leagues.list`, `league.set`, `rates.*` answer `unknown_type` for now: TODO(Phase C) in `Gateway.Routes` and `Gateway.Socket`.
  - Health: `Quicksilver.Health.report(source, attrs)`; `poe_ninja` and `trade_leagues` registered `idle`; `health` pushed after `welcome`, then every 5 s.
  - Settings: `settings.json` in `:filename.basedir(:user_config, "Quicksilver")`, atomic writes (temp file + fsync + rename), corrupt file moved to `.corrupt`, dir overridable.
  - Tests: 67 (66 by default + 1 opt-in e2e that boots `mix run`, reads READY, handshakes, closes stdin, checks exit). All pass with the network off (run in a loopback-only namespace).
- Decisions (readings of PROTOCOL where the text is silent; see questions below):
  - Any frame before `hello` that isn't a `hello` envelope, including invalid JSON and binary frames, gets `unauthorized` + close (not `bad_json`).
  - A `hello` with a missing or mistyped `protocol_version`/`client_version` gets `bad_request` + close. Check order: `protocol_mismatch` → `bad_request` → `unauthorized`, so an old/new client always gets the "reinstall" message.
  - Handshake failures close with WebSocket status 1008.
  - A second `hello` after the handshake gets `bad_request`; the connection stays open.
  - An envelope `id` that isn't a string or null gets `bad_json` (with id `null`).
  - The client's `ts` isn't validated.
  - No WebSocket idle timeout (the client may stay silent; health pushes keep flowing).
  - A crashed listener restarts on the same port it first bound, so the single READY line stays true.
  - Dev-only env var `QUICKSILVER_EXIT_ON_STDIN_EOF=0` turns off the stdin guard (the client never sets it).
- Problems / surprises:
  - Bandit's default WebSocket idle timeout is 60 s; it's set to `:infinity` on purpose.
  - `WebSockAdapter.UpgradeError` has no `plug_status`, so it's rescued to return 400 instead of 500.
  - On Windows, verify in B6: (1) stdin EOF detection under `erl -noshell` in a release, (2) `File.rename` replacing an existing `settings.json`.
- Handoffs:
  - **integrations (I1/I2):**
    - Report status with `Quicksilver.Health.report(:poe_ninja | :trade_leagues, status: :ok | :degraded | :down | :idle, cached_at: DateTime, detail: "...", rate_limit: %{policy:, queued:, restricted_until:})`. Full contract: the `Quicksilver.Health` moduledoc. It's a cast, so it never blocks; invalid args raise in the caller.
    - Put your supervisor in `Quicksilver.Application` children between `Health` and the `Endpoint` (marked with a comment).
    - Suggested home: `lib/quicksilver/integrations/` / `Quicksilver.Integrations.*`, so lane ownership is path-clear.
    - Add your own HTTP client dependency. `mint` is only present as a test dependency.
  - **frontend (F1):**
    - Read or redirect the backend's **stderr** as well as stdout: logs go to stderr, and a full pipe would block the backend.
    - The READY line matches `^QUICKSILVER_READY \{"port":(\d+),"protocol_version":1\}$`.
    - Handshake failures arrive as an `error` message followed by close code 1008.
  - **owner (PROTOCOL questions; I didn't edit PROTOCOL.md):**
    1. Confirm the readings above: pre-hello garbage → `unauthorized`; bad hello payload → `bad_request` + close; check order; second hello → `bad_request`; non-string id → `bad_json`; close code 1008.
    2. Which `hello` fields are required? Implemented: `protocol_version` (integer) and `client_version` (string) always; `token` only when the backend has one.
    3. Security proposal: reject WebSocket upgrades that carry an `Origin` header, so a web page in the user's browser can't connect to `ws://127.0.0.1:47474` (matters in dev, where there's no token). Check first that QWebSocket sends no Origin by default. This would be a PROTOCOL change, so it's not implemented.
    4. Consider documenting `QUICKSILVER_EXIT_ON_STDIN_EOF` as dev-only in "Launch and lifetime", or say it's out of scope.
- Next step: integrations I1/I2, then the backend Phase C Dashboard handler (`leagues.list`, `league.set`, `rates.*`), with rates pushes via a subscriber registry.
