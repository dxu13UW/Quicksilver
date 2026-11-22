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

### 2026-11-19: Moving development from WSL to native Windows (handoff)
- Who: me + Claude Code (WSL session; the last one in WSL)
- Goal: review B1/B2, then prepare the repo to move from WSL (Debian) to native Windows before the codebase grows.
- Done:
  - Reviewed and committed B1/B2 (`3fea626`). `mix test` re-run by the main session: 67 tests, 0 failures, 1 excluded (e2e). Format is clean, there are no HTTP clients, and the listener is loopback-only.
  - Settled the backend agent's PROTOCOL questions in PROTOCOL.md: required hello fields, check order, close code 1008, frames before hello → `unauthorized`, second hello → `bad_request`, id/ts rules, stdout/stderr, and the dev-only `QUICKSILVER_EXIT_ON_STDIN_EOF`. **Added an Origin check** (upgrades that carry `Origin` get 403).
  - Added `.gitattributes` (LF everywhere; CRLF for .bat/.cmd/.ps1). Rewrote the ADR-001 dev environment for native Windows, and added a dev-environment line to CLAUDE.md.
- Decisions: develop natively on Windows (ADR-001, Obsidian D21). The repo is at `C:\dev\Quicksilver`.
- Problems / surprises: Windows already had Git 2.46, Erlang/OTP 27 and Elixir 1.18.0. Still missing on 2026-11-19: VS 2022 Build Tools and Qt 6.8 (with Qt WebSockets).
- Handoffs:
  - **Backend (Phase C):** implement the Origin check (403), then the dashboard routes (TODOs in `gateway/routes.ex` and `gateway/socket.ex`).
  - **Frontend (F1):**
    - Create `QWebSocket` with an empty origin, and check it sends no `Origin` header.
    - Drain the backend's stdout **and** stderr.
    - Put the backend in a Job Object with kill-on-close.
  - **B6 checks, now testable early on Windows:**
    - Does stdin EOF stop the backend (`mix run` from Git Bash and PowerShell, and later a release)?
    - Does `File.rename` replace an existing `settings.json`?
- Next step, **first thing in the Windows session**:
  1. Clone, and set the repo identity (`git config user.name dxu13UW`, `user.email 252822825+dxu13UW@users.noreply.github.com`).
  2. `cd backend && mix deps.get && mix test`, plus `mix test --include e2e`. All must pass on Windows. Fix anything Windows-specific first.
  3. Smoke-test by hand: run `mix run --no-halt` in one terminal, and check that the READY line appears and Ctrl+C / closing stdin stops it.
  4. Continue Week 2 with integrations I1/I2 (poe.ninja + trade league clients, rate limiter, cache, Health reporting). Then backend Phase C, Q1, and F1/F2 once Qt is installed.
  5. Keep appending every design decision to the Obsidian note `C:\Users\turtl\Documents\Obsidian\TCSS490 Generative AI and Software Development\Artifact 5.md`, as the next D-number.

### 2026-11-19: I1 + I2 poe.ninja client, league list, rate limiter
- Who: integrations agent
- Goal: PLAN I1 (poe.ninja client with cache and refresh schedule: currency plus one item category) and I2 (league list from the official API; league selection stored in backend config).
- Done:
  - `Quicksilver.Integrations.*` in `backend/lib/quicksilver/integrations/`. Subtree `Integrations.Supervisor` (rest_for_one: PubSub Registry → TaskSupervisor → RateLimiter → Leagues → PoeNinja), added to `Quicksilver.Application` between Health and the Endpoint.
  - `HTTP.get_json/2`: the only external HTTP path. It sends the project User-Agent, gzip and JSON accept headers, and goes through the limiter. Adapters: `MintAdapter` (TLS verify_peer + `cacerts_get`), `Disabled` (refuses; default in the test env and with `QUICKSILVER_OFFLINE=1`).
  - `RateLimiter`: limits only from `x-rate-limit-*` headers. Per-policy hit history, resynced from `-State`. Requests queue (FIFO), never dropped. One in flight until a policy is seen, and always for hosts that send no headers. Pauses on an active restriction or a 429 (`max(Retry-After, restriction)`). Reports `rate_limit` to Health for mapped buckets.
  - `Leagues`: trade league list (PC, source order), cached 1 h, fetched at startup. Current league = saved setting → first PC league → `Standard`. `set_current` validates, saves `"league"` via `Quicksilver.Settings`, broadcasts. Health `trade_leagues`.
  - `PoeNinja`: index-state (1 h) + `Currency` (exchange) + `UniqueAccessory` (stash) for the current league. TTL = `max-age − Age` (fallback 30 min, floor 60 s). Stale-if-error from the header (fallback 24 h). Back-off retries. Pushes rates on refresh and on league change. Health `poe_ninja`.
  - `mint` moved from test-only to a runtime dependency (already in `mix.lock`; nothing new downloaded).
  - Recorded fixtures in `backend/test/fixtures/integrations/` (trade leagues, index-state, Currency, UniqueAccessory trimmed to 15 lines), replayed by `test/support/integrations/fixture_http.ex`.
  - Tests: 46 new (HTTP/CacheControl, parsers, rate limiter with an injected clock, Leagues, PoeNinja, app subtree). Whole suite: 118 tests, 0 failures (117 + 1 e2e). `mix test` is offline by construction.
  - DATA_SOURCES.md: implementation notes, TTL table filled in, new endpoint facts, behaviour-change log entry.
- Decisions:
  - Freshness is `max-age − Age`, because poe.ninja is behind Cloudflare. Refetching at plain `max-age` would only get the same CDN copy later.
  - Rate check reads "would exceed `max`", not "would reach": the last slot of a tier is usable, with a 500 ms margin on window expiry. DATA_SOURCES wording updated to match.
  - `divine_chaos` comes from the exchange `divine` line (so the Divine row is exactly 1.0 div), falling back to `1 / core.rates.divine`.
  - poe.ninja is only asked about leagues its index-state lists (Ruthless leagues are never requested; Health shows `down` with "poe.ninja has no data for <league>").
  - A saved league that has ended is replaced by the default for the run, but the saved value isn't overwritten. Only an explicit `set_current` writes it.
  - `set_current` to the same league still broadcasts `league_changed`, so a fresh `rates.update` follows (PROTOCOL).
  - Test-env defaults (no network, no auto refresh) are decided in `Integrations.Config` at compile time, because `config/` belongs to the backend lane.
  - Caches are in memory only for now: an offline start has no league list (falls back to the saved league or `Standard`).
- Problems / surprises:
  - Live (2026-11-19): 1 div = 216.2 c (145.7 c on 11-15). index-state lost `snapshotVersions`. The exchange overview does include a `divine` line. `divineValue` is missing on about 30% of UniqueAccessory lines. Neither host sends rate-limit headers on these endpoints. The trade league list once came back with `Age: 1534` against `max-age=120` (stale CDN copy). Offered `br`, poe.ninja answers in brotli, so we offer only gzip.
  - TLS to both hosts verifies fine from Erlang/OTP 27.2.
  - Live calls made: 4 with curl (recording) + 8 from the Erlang client (two smoke runs), all with the project User-Agent.
  - Out-of-lane edits: the agreed one line in `application.ex`; `test/quicksilver/application_test.exs` (child count 3 → 4, plus asserting the integrations supervisor), which the added child makes unavoidable; and the `mix.exs` deps entry (sanctioned). New support files under `test/support/integrations/`.
- Handoffs:
  - **backend (Phase C, Dashboard routes)**: public API in `Quicksilver.Integrations` (moduledoc has the details and the error-code table):
    - `list_leagues(timeout \ 15_000) :: {:ok, [%{id, text}]} | {:error, :unavailable}`. Waits for the first fetch if one is running.
    - `current_league() :: String.t() | nil`. Use it for `welcome.league` and `leagues.result.current`.
    - `set_league(id) :: :ok | {:error, :unknown_league | :unavailable | {:settings, reason}}`.
    - `rates(opts \ []) :: {:ok, rates} | {:error, :no_league | :league_not_covered | :unavailable}`. `rates` has exactly the `rates.update` fields; only `fetched_at` is a `DateTime` (use `Quicksilver.Time.iso8601_ms/1`). It waits for the first fetch if nothing is cached yet.
    - `item_prices(type, opts \ [])`, for Week 3.
    - `subscribe(:rates | :league)` / `unsubscribe/1`: Registry-based and idempotent, and they end with the process. Messages: `{Quicksilver.Integrations, :rates, rates}` and `{Quicksilver.Integrations, :league_changed, id}`. Suggested flow: each socket process subscribes to `:rates` on `rates.subscribe` and turns each message into a `rates.update` push (id null). After `league.set`, no extra push is needed: a rates message follows from cache or after the fetch.
    - In the test env the app's integrations processes run but never fetch (`HTTP.Disabled`, no auto refresh). Calling `list_leagues/0` or `rates/0` there would set the app's Health entries to `down`, so gateway tests should stub at the gateway level or start private instances (see `test/support/integrations/integrations_case.ex`).
    - Please add `{~c"QUICKSILVER_OFFLINE", ~c"1"}` to the env in `test/e2e/launch_e2e_test.exs`: the dev boot otherwise makes a few live requests (league list + poe.ninja) during the e2e test. It passes either way.
    - Optional: move the test-env defaults into `config/test.exs` as `config :quicksilver, Quicksilver.Integrations, http_adapter: Quicksilver.Integrations.HTTP.Disabled, auto_refresh: false` (the compile-time defaults would then be redundant but harmless).
  - **owner**: append the decisions above to the Obsidian decision log.
- Next step: backend Phase C wires the Dashboard routes to this API. Integrations next: I3 (trade search/fetch, Week 3), and keeping the last good league list on disk for offline starts.

### 2026-11-19: First native Windows session: B1/B2 verified, Origin check, I1/I2 review
- Who: me + Claude Code (main session; backend and integrations agents)
- Goal: run the Windows checks from the WSL handoff, then continue Week 2.
- Done:
  - `mix test` and `mix test --include e2e` pass on Windows: 118 tests, 0 failures, after Origin and I1/I2.
  - B6 checks for the dev build: stdin EOF stops the backend (`mix run` from Git Bash), and `File.rename` replaces an existing `settings.json`. Re-check with a release later.
  - Fixed `test/e2e/launch_e2e_test.exs` for Windows: it starts `erl.exe` directly instead of `mix.bat`, and sets `QUICKSILVER_OFFLINE=1` (handoff from integrations).
  - Backend agent: Origin check. Any `Origin` header on `/ws` → 403 `Forbidden`, checked before upgrade validation; `test/quicksilver/gateway/origin_test.exs` (5 tests); `WSClient.connect/3` takes optional headers. PROTOCOL.md updated to the implemented behaviour.
  - Reviewed the I1/I2 entry above: the full suite passes, there's no HTTP outside `Integrations.HTTP`, and the User-Agent is set. The integrations agent's edit to `application_test.exs` (now 4 children) is accepted.
- Decisions: launch the backend without cmd.exe in between, or with `cmd /d` (Obsidian D23).
- Problems / surprises:
  - Erlang/OTP 27.2 rejects the `builds.hex.pm` TLS chain (Let's Encrypt "YR": key_usage_mismatch), so Mix couldn't install rebar3. Installed rebar3 3.24.0 by hand from its GitHub release (`mix local.rebar rebar3 <file>`). poe.ninja and pathofexile.com verify fine. A later OTP upgrade should fix it.
  - This machine's cmd.exe AutoRun (`%USERPROFILE%\alias.cmd`) prints a banner and changes into `Code_dir\tools` on every cmd start.
  - Under an Erlang port on Windows, output from programs that cmd.exe starts never reaches the pipe, though cmd's built-in `echo` does.
  - The Erlang VM sets `ERL_CONSOLE_MODE=windowed` in its environment (it wasn't the cause here, but children inherit it).
- Handoffs:
  - **Frontend (F1):** start the backend with QProcess on `erl.exe`/the release executable, or through `cmd /d /c`; never a plain `.bat` launch (AutoRun). Confirm that QWebSocket sends no `Origin` header, or the backend returns 403.
  - **Backend (Phase C):** wire `leagues.list`, `league.set` and `rates.*` to `Quicksilver.Integrations` (see the I1/I2 entry).
- Next step: the owner installs VS 2022 Build Tools (C++ workload) and Qt 6.8 (MSVC 2022 64-bit + Qt WebSockets). Then a toolchain smoke build, F1, backend Phase C, F2, and Q1.

### 2026-11-19: F1 Qt client: command center, backend launch, connection status
- Who: frontend agent
- Goal: PLAN F1. `Quicksilver.exe` starts the backend, connects per PROTOCOL v1, and shows the connection status (CON-1, CON-2, CON-4).
- Done:
  - CMake project in `frontend/`:
    - `quicksilver_core` static lib (no widgets), the `Quicksilver` WIN32 exe, and Qt Test exes under `tests/`.
    - `frontend/build.bat` does configure + build + ctest in one command (`clean`, `notest` args). A post-build `windeployqt` makes the exe run by double-click. How to run: `frontend/CLAUDE.md`.
  - Classes (`src/core` unless noted):
    - `protocol_codec`: pure functions for the READY line, envelope encode/decode, token, hello.
    - `ProtocolClient`: one QWebSocket with an empty origin, so no `Origin` header. Sends hello, matches replies to `c-<n>` ids (order doesn't matter), and emits push/health/error-push signals. A handshake `error` followed by a 1008 close becomes `handshakeFailed`.
    - `BackendProcess`:
      - Uses a token from the OS crypto RNG, `QUICKSILVER_PORT=0`, and strips `QUICKSILVER_EXIT_ON_STDIN_EOF`.
      - Waits up to 20 s for READY; other stdout lines go to the log.
      - Drains stderr into `%LOCALAPPDATA%\Quicksilver\logs\backend.log` and a 500-line ring.
      - To stop: closes stdin, waits 3 s, then ends the job.
    - `BackendConnection`: owns both and the retry policy; it's the UI's status source.
    - `BackendLocator`: picks the backend command.
    - `app_log`: writes `client.log`.
    - `src/platform/`: `ProcessJob` and `ChildStdin` (Windows), with stubs for other OSes.
    - `src/ui/CommandCenterWindow`: status card (dot, headline, detail, Restart button), a raw health tree, and the backend log tail. Help → About carries the GGG notice.
  - Dev launch: `erl.exe -noshell -elixir_root <Elixir>\lib -pa <Elixir>\lib\elixir\ebin -s elixir start_cli -extra <Elixir>\bin\mix run --no-halt`, cwd `backend/`, erl and elixir found on PATH. Overrides: `QUICKSILVER_BACKEND_DIR`, `QUICKSILVER_ERL`, `QUICKSILVER_ELIXIR_ROOT`. Release hook: `QUICKSILVER_BACKEND_EXE`/`_ARGS`/`_DIR`; `.bat`/`.cmd` are refused. `QUICKSILVER_READY_TIMEOUT_S` overrides the 20 s wait.
  - Tests: 5 ctest executables, 81 Qt Test cases, all passing from a clean `build/`:
    - codec 42
    - client against a fake server 16, including a raw-TCP check that the upgrade request has no `Origin`
    - locator 11
    - process job 7
    - e2e against the real backend 5: connect + health + `unknown_type`; a killed backend is restarted and reconnected in 1.9 s (0.14 s after its READY); wrong token → `unauthorized`; protocol 2 → `protocol_mismatch` + `expected: 1` + close 1008; an `Origin` header → 403; stdin shutdown in about 1.06 s.
  - Manual run of `Quicksilver.exe`: connected 1.0 s after launch (from `client.log`).
    - Closing the window: the backend logged "stdin closed; shutting down" and exited with code 0; no `erl.exe` was left.
    - `taskkill /F` on Quicksilver.exe: the Job Object ended `erl.exe` immediately.
- Decisions:
  - Retry policy. REQUIREMENTS CON-4 gives the target, not the mechanism, so this is my choice:
    - Socket lost while the backend still runs: reconnect after 0.5/1/2/4/5 s; after 5 failures, restart the backend.
    - Backend exited on its own: restart after 1/2/4/8/15 s; give up after 5 restarts that never reach connected.
    - No automatic retry for a READY timeout, a start failure, `protocol_mismatch`, `unauthorized` or `bad_request`. These show Failed with a Restart button.
    - A welcome resets the counters.
  - A READY line with another `protocol_version` is reported at once as the "Reinstall Quicksilver" mismatch, not after a 20 s timeout. The parser accepts any version; only 1 is used.
  - Job Object without a race: the child is created with `CREATE_SUSPENDED` (QProcess CreateProcess modifier), assigned to the job, then resumed with a Toolhelp thread snapshot. This uses only public Qt API.
  - `welcome.league` null shows as "not chosen yet".
- Problems / surprises:
  - **erl.exe never reads QProcess's stdin on Windows.** QProcess gives the child a named pipe; `erl -noshell` gets neither the data nor EOF from it, while `sort.exe` reads it fine. Erlang ports, and cmd, use anonymous pipes, which is why the backend e2e test passed. At first, quitting took 3 s and the backend exited with code 1 because the job killed it. Fix: `platform::ChildStdin` gives the child an anonymous `CreatePipe` read end through the same CreateProcess modifier; our write end is never inheritable. Graceful exit now takes about 1 s with exit code 0. A test asserts the shutdown goes through stdin. **B6 should keep this in mind:** any launcher must give the release an anonymous pipe for stdin.
  - `QStandardPaths::findExecutable(name, {})` searches this process's PATH when the list is empty, so `BackendLocator` guards against that.
  - Qt Test's console output can vanish under Git Bash; use `-o file,txt`.
  - Another agent changed `backend/` and PROTOCOL.md (Phase C) during this session. F1 already matches the new rules: replies are matched by id, and `serverError` now passes the full payload so F2 can read the rates error push's `topic`/`league`.
- Handoffs:
  - **backend (B6):** stdin EOF needs an anonymous pipe on Windows (see above). If the release entry point is only `bin\quicksilver.bat`, the client can't launch it (cmd is never allowed in between); provide an .exe entry point (e.g. `erl.exe` from the release's `erts-*/bin` with the boot args), and the client sets `QUICKSILVER_BACKEND_EXE`/`_ARGS`.
  - **qa (Q1):** the frontend tests cite CON-1/2/3/4, NFR-SEC-2 and NFR-MNT-2. `ctest -LE integration` skips the real-backend test.
  - **owner:** add to the Obsidian decision log: the retry policy, `ChildStdin` (anonymous-pipe stdin), and CREATE_SUSPENDED + job assignment.
- Next step: F2 (rates table, league selector, health panel), using `BackendConnection::client()->request(...)` and `pushReceived`, now that backend Phase C is landing.

### 2026-11-19: Qt toolchain, backend Phase C, two PROTOCOL decisions
- Who: me + Claude Code (main session; backend agent for Phase C)
- Goal: install and verify the Qt toolchain, build the dashboard routes, and review F1 (its own entry is above).
- Done:
  - Installed Qt 6.8.3 (MSVC 2022 64-bit + Qt WebSockets, 2.3 GB custom install) and VS 2022 Build Tools (MSVC 19.44, plus the CMake and Ninja that ship with it). A smoke build and run against the real backend confirmed a default `QWebSocket` sends **no Origin header**.
  - Fixed this machine's cmd AutoRun, which broke `vcvars64.bat`: VsDevCmd's `for /f` subshells ran `alias.cmd`, which printed a banner and changed directory. `C:\Users\turtl\alias.cmd` now returns at once for non-interactive cmd (`/c`); the original is in `alias.cmd.bak`. Gotcha: substring substitution on `CMDCMDLINE` changes the real command line in place, so copy it first.
  - Backend Phase C (backend agent): `leagues.list`, `league.set`, `rates.subscribe` and `rates.unsubscribe` in `Gateway.Handlers.Dashboard`, through a `Gateway.DataSource` interface (production calls `Quicksilver.Integrations`).
    - Slow upstream calls run in `Quicksilver.Gateway.TaskSupervisor` tasks, so the socket never blocks.
    - Pushes that arrive while a reply is pending are held back, so the reply always comes first.
    - The application now has 5 top-level processes.
  - Reviewed F1 (frontend agent). A clean `build.bat` passes all 5 ctest programs (81 cases, including the real-backend e2e). There is no external HTTP; the only `OpenProcess` call is on our own backend child, to add it to the Job Object.
  - Backend: 155 tests, 0 failures (including e2e). PLAN: B1, B2, I1, I2, F1 and the toolchains are ☑; F2 is ◐.
- Decisions (PROTOCOL.md updated first; Obsidian D26):
  - `welcome.league` is the **active** league (= `leagues.result.current`), not the saved setting. A data source that doesn't answer can't hold up the handshake: after 500 ms, `null` is sent.
  - **Rates error push:** when a subscribed client's league changes and there are no rates for it, the server pushes error `upstream_unavailable` with id `null` and `{"topic": "rates", "league": ...}`. It isn't repeated for the same league, and it's dropped if the league changes again before the check finishes.
  - Clarified: `league.set` with no league list available → `upstream_unavailable`. Replies may arrive out of order (match by id). Error `message` text is display-only.
- Problems / surprises:
  - Running vcvars from Git Bash with inline quoting fails; use a `.bat` file via `cmd /d /c` (`frontend/build.bat`).
  - From the F1 entry: on Windows, `erl.exe` never sees EOF on QProcess's stdin pipe. F1 gives it an anonymous pipe instead (`child_stdin_win.cpp`).
- Handoffs:
  - **Frontend (F2):**
    - Build the dashboard on `connection->client()`: a rates table from `rates.update`, and a league selector (`leagues.list` / `league.set`).
    - Handle the rates error push (`serverError` with `topic == "rates"`).
    - The health panel replaces F1's raw table.
  - **Backend (B6):** the release needs an `.exe` entry point (no `.bat` through cmd), and its stdin must be an anonymous pipe (see the F1 entry).
  - **QA (Q1):** a protocol test plan covering the whole v1 surface. Tests already cite CON-1–4, DASH-1/2, NFR-REL-3, NFR-SEC-2 and NFR-MNT-2.
- Next step: F2 (frontend), Q1 (qa), then the Week 2 portfolio update.

### 2026-11-21: F2 dashboard: league selector, rates table, health panel
- Who: frontend agent
- Goal: PLAN F2. The command center dashboard: currency rates table, league selector and backend health panel on PROTOCOL v1 (DASH-1, DASH-2, DASH-3; CON-3, CON-4, NFR-REL-3, NFR-UX-3).
- Done:
  - Core, no widgets (`src/core/`; `quicksilver_core` now also links QtGui, for colours in item models):
    - `Dashboard` wires the three below to one `ProtocolClient`.
    - `LeagueController`: `leagues.list` on every welcome; `select()` → `league.set`; pending/success/error with revert.
    - `RatesFeed`: `rates.subscribe` on every welcome (so it re-subscribes after each reconnect); `rates.update` reply/push; the subscribe error and the rates error push → cleared table + message; last rows kept while disconnected.
    - `RatesModel` + `RatesSortProxy`, `HealthModel`, `dashboard_format` (all number/age wording).
  - UI (`src/ui/`, new static lib `quicksilver_ui` so widget tests can link it):
    - `CommandCenterWindow`: compact connection strip on top, then tabs "Dashboard" and "Backend log".
    - Dashboard tab: `LeagueSelector` row, then a vertical splitter with `RatesPanel` above `HealthPanel`.
    - `RatesPanel`: heading "Currency rates · <league>"; meta line "poe.ninja · updated N min ago · 1 divine = N chaos"; STALE and OFFLINE chips; name filter; a table or a message page (waiting / loading / no rates / empty).
    - `HealthPanel`: one row per source in the given order, a status pill (idle/ok/degraded/down; grey "unknown" while disconnected), last success, cache age, detail, rate limit.
  - Tests: 9 ctest programs, 156 Qt Test cases, all passing from a clean build dir (`build.bat clean`). New:
    - `tst_dashboard_format` 27
    - `tst_rates_model` 12: parse, in-place update, numeric sort, nulls last, ties, sort kept across refreshes
    - `tst_dashboard_client` 23: Dashboard against the fake server (leagues.result, league.set ok/error/revert, out-of-order replies, rates.update, stale, subscribe error, rates error push, reconnect re-subscribes, health)
    - `tst_dashboard_widgets` 12: offscreen widgets. A programmatic fill sends nothing; a user keypress sends exactly one `league.set`; an error reverts the combo; refresh keeps sort and scroll.
    - e2e +1: the real backend with `QUICKSILVER_OFFLINE=1` gives `leagues.list` → `upstream_unavailable`, the rates Error state, health, and `league.set` → `upstream_unavailable` + revert (nothing saved).
  - Live run, online, of the new `Quicksilver.exe`:
    - Real data: 8 PC leagues; Covens 108 rates (1 div = 213 c); one user keystroke → one `league.set "Standard"` → 100 Standard rows (1 div = 802 c).
    - Relaunch: Standard was restored (DASH-2). Switching to "Ruthless" shows "No rates for Ruthless / poe.ninja has no prices for this league."
    - Health: poe.ninja and the league list went idle → ok. Closing the window: the backend exited with code 0.
    - Screenshots: `frontend/build/f2-live/` (not committed).
  - Dev aids:
    - `QUICKSILVER_LOG_DIR` (log folder), `QUICKSILVER_SNAPSHOT_DIR` (window PNGs after dashboard changes).
    - `build.bat` honours `QS_BUILD_DIR`.
    - Test exes now build into `build/tests/`.
- Decisions:
  - Only the combo's user-only `activated()` sends `league.set`; fills run under `QSignalBlocker`.
  - One league change in flight at a time. The combo stays enabled while it's pending (disabling it threw keyboard focus elsewhere); choices made meanwhile snap back.
  - A `leagues.result` requested before a successful change doesn't overwrite `current` (out-of-order replies).
  - After `league.changed` for another league, the table clears to "Loading rates for X…" instead of showing the old league's rows under the new name.
  - Same-league `rates.update`s update rows in place, keyed by `id` (no model reset), so the user's sort and scroll stay. Null `change_7d`/`volume_chaos` sort last in both directions; ties keep the backend order.
  - Disconnected: the last rates stay, marked OFFLINE (NFR-REL-3); health rows stay but turn grey "unknown".
  - The connection strip no longer repeats `welcome.league` (it went stale after a switch); the selector owns the league.
- Problems / surprises:
  - Test exes sat next to `Quicksilver.exe` and loaded windeployqt's `Qt6Cored.dll`. Qt then looked for plugins in `build/platforms` (qwindows only), so the offscreen widget test hit `qFatal` and hung on the Debug abort dialog. Fixed with a separate output directory.
  - The owner had `build\Quicksilver.exe` open (started from Explorer at 13:11), which locks `build/`. I didn't close it: iteration and the final `build.bat clean` ran with `QS_BUILD_DIR` set to a scratch folder.
  - `%APPDATA%\Quicksilver\settings.json` didn't exist before this session. My runs saved Standard and then Ruthless (13:45:40), but at 13:45:47 something else wrote `"league": "Covens"`: the owner's running instance or another agent's test. I left the file as it is.
  - The UIA "SetFocus" on the Qt combo didn't move keyboard focus. The live switches used Tab plus combo keyboard search. The script sent keys only after checking that our window was in front and the combo had focus.
- Handoffs:
  - **backend / protocol questions:**
    1. On a cold start, `rates.subscribe` answered `upstream_unavailable` within about 25 ms (no league yet), and the rates arrived as a push about 0.8 s later. PROTOCOL says subscribe waits for the first fetch. The UI briefly shows "No rates available". Could subscribe wait for the league, like `leagues.list` does?
    2. Offline: `welcome.league` is null and `leagues.list` fails, so the client never learns the active league. The backend then picks `Standard` and pushes a rates error for it. The amended PROTOCOL says the client learns the league from `leagues.list`, which can't happen here. Should there be a `league.changed` push (id null) when the backend picks or changes the league itself?
    3. With `QUICKSILVER_OFFLINE=1`, health still reports `poe_ninja` and `trade_leagues` as `idle` after failed requests. If a real network loss behaves the same, DASH-3 ("unplug → degraded/down") won't show. Worth a check.
    4. The selected league is shared by every instance through settings.json (see above). That's fine for one user, but it's worth knowing for tests that call `league.set` against a dev backend.
  - **qa:** the new tests cite DASH-1/2/3, CON-3/4, NFR-REL-3, NFR-UX-3 and NFR-MNT-2. Widget tests need `QT_QPA_PLATFORM=offscreen` (ctest sets it).
  - **owner:**
    - Add to the Obsidian log: user-only `activated()`, one change in flight, in-place id-keyed rate updates, last data kept OFFLINE.
    - Rebuild in `build/` (`build.bat clean`) once your running Quicksilver.exe is closed.
- Next step: Q1 review of F2, then the Week 2 portfolio update. Mark F2 ☑ in PLAN after the owner's check.
- Addendum (same day, after the owner's decision on the `league.changed` push):
  - `LeagueController` now handles the `league.changed` **push** (id null). It sets `current()` without sending anything and emits `backendChanged`; the selector shows "Backend switched to X" and the rates feed goes to "loading" for X, as after a user switch.
  - While a user `league.set` is pending, the pending choice stays shown and the reply decides. `current()` still follows the push, so a failed change reverts to the backend's real league, and the rates feed expects that league.
  - A push also invalidates the `current` of a `leagues.result` that is still in flight.
  - `WelcomeInfo::healthIntervalS` is now a `double` (PROTOCOL: a number, which may be fractional).
  - Tests: +4 fake-server cases (a push selects without sending; a push before an old list reply; a push during a pending set, both on success and on error) and +2 widget cases (the combo and the note update without `league.set`; the pending choice stays shown). The welcome test now checks a fractional `health_interval_s`. All 9 ctest programs pass: 162 cases (built with `QS_BUILD_DIR`, because the owner's window still locks `build/`).

### 2026-11-21: Q1 test plan + QA review, gap tests, league.changed push, cold-start rates
- Who: me + Claude Code (main session; qa, backend, integrations and frontend agents)
- Goal: finish the Week 2 build items: F2 (entry above), Q1, and the follow-ups from QA and F2's live run.
- Done:
  - **Q1 (qa agent):** created `docs/TEST_PLAN.md` with 150 cases, each citing requirement IDs: 120 covered, 11 partial, 6 gaps, 4 pending F2, and 9 N/A or review only. It also has a 19-step manual checklist and the run commands.
    - QA review, against the committed `fc06e93` plus the backend:
      - Protocol: **PASS**
      - Compliance: **PASS**
      - External calls: **PASS**
      - Tests: **PASS**
      - Requirements: **PASS**
      - Docs: **PASS** (3 low fixes, all done below)
    - No blockers.
  - **PROTOCOL.md clarified from QA's findings:**
    - the 500 ms `welcome.league` null fallback;
    - a malformed `hello` envelope → `unauthorized` (`bad_request` only for bad payload fields);
    - `health_interval_s` is a number;
    - a pending subscribe reply is still sent after an unsubscribe;
    - the subscribe-error reply vs the rates error push;
    - `league.set` to the same league still pushes rates.
  - **Gap tests:**
    - Backend: two-fault handshake order (TP-HS-013/014), a binary frame before hello (TP-ENV-011), a malformed hello, an empty `Origin` (TP-HS-017), and a plain `GET /ws` with Origin (TP-HS-018). Also fixed the stale close-code comment in `socket.ex`.
    - Integrations: null `change_7d`/`volume_chaos` (TP-RATES-013) and poe.ninja back-off (TP-API-012). Requirement IDs added to the 4 integrations test files.
  - **Cold-start rates (integrations agent):** `Integrations.rates/1` now waits, bounded by `:timeout`, for the first league instead of returning `:no_league` at once. This fixes F2's brief "No rates available" at startup.
  - **`league.changed` push (backend + frontend agents):**
    - Every connection now gets `league.changed` (id null) when the backend changes the league itself. The client that sent `league.set` gets only its reply.
    - The push always comes before that league's rates. A duplicate rates error on cold start was found and suppressed.
    - F2 shows "Backend switched to X" without sending anything back.
  - **Verified by the main session:** backend `mix test --include e2e` 3×: 174 tests, 0 failures, format clean. Frontend clean build (`QS_BUILD_DIR`): 9/9 ctest programs, 162 cases, against the new backend. F2 code: no HTTP and no input injection. PLAN: F2 ☑, Q1 ☑.
- Decisions (PROTOCOL.md updated first; Obsidian D28):
  - The backend pushes `league.changed` when it picks or changes the league on its own.
  - A cold-start `rates.subscribe` waits for the first league.
- Problems / surprises:
  - The owner's real `%APPDATA%\Quicksilver\settings.json` is shared by every dev run that switches leagues; it's at `"Covens"` now. Automated tests never write there (`_build/test/settings`).
  - Agents running `mix test` at the same time can collide on ExUnit `tmp_dir` paths. Seen once; not reproducible when only one suite runs.
  - The owner's open `Quicksilver.exe` locks `frontend/build/`. `build.bat` now takes `QS_BUILD_DIR`.
  - F2's live run drove our own window with Windows UI Automation. That's fine under COMPLIANCE, which is about the game; never point such scripts at the game client.
- Known minor issues (not fixed):
  - The `poe_ninja` Health can stay `degraded` for up to the retry interval (≤ 30 min) after cached data passes `stale-if-error`, before it turns `down`. A timer at `stale_until` would fix it.
  - With `QUICKSILVER_OFFLINE=1`, health stays `idle`. Check DASH-3 (network loss → degraded/down) manually with a real network loss.
  - Remaining TEST_PLAN gaps: `BackendConnection` unit tests (the retry policy, the "Reinstall" text, the READY timeout), launch-env stripping and stdout draining, and a lint against direct HTTP calls (TP-CMP-001/002).
- Handoffs:
  - **Owner:** collect 20+ item texts into `shared/samples/` before Week 3 (B3 needs them).
  - **QA:** update TEST_PLAN statuses for the new tests and the F2 cases.
  - **Frontend:** the BackendConnection unit tests above.
- Next step: the Week 2 portfolio update (scribe), commit, then Week 3 (B3 parser, B4 pricing, I3 trade client, F5).

### 2026-11-21: Manual UI test pass + app icon
- Who: me + Claude (main session)
- Goal: test every UI-testable Week 2 feature by hand before the commit; add the app icon.
- Done:
  - Clean rebuild of `frontend/build` with F2. The owner ran the manual checklist and every item passed: startup and status, health panel, league switch and persistence, Ruthless "no rates" state, sort and filter, Restart backend, backend killed and recovered, no `erl.exe` left after a normal close or a force-kill.
  - App icon: the owner's winged-Mercury stone medallion, `frontend/resources/icons/quicksilver.svg`. `make_icons.ps1` renders it to PNGs (16–256 px) with headless Edge and packs `quicksilver.ico`. The exe icon comes from `resources/quicksilver.rc`; the window and taskbar icon from the `.qrc` PNGs via `QApplication::setWindowIcon`. Rebuilt; 9/9 ctest.
- Decisions: icons are rasterised by a browser, not Qt SVG, because the SVG uses filters (`feTurbulence`, `feDisplacementMap`, `feDropShadow`) that Qt SVG ignores. The generated PNGs and `.ico` are committed, so the build needs no browser.
- Problems / surprises: none.
- Handoffs: none.
- Next step: commit and push, then Week 3.
