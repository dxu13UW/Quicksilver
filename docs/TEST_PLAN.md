# Test plan

Owner: QA agent. Created for PLAN item **Q1** (Week 2), 2026-11-21.
Every test case names the REQUIREMENTS.md ID(s) it verifies. PROTOCOL.md v1 is the source of truth for message shapes; when this plan and PROTOCOL.md disagree, PROTOCOL.md wins and this plan gets fixed.

## 1. Purpose and scope

**In scope (Week 2):** the PROTOCOL v1 sections marked final (Launch and lifetime, Envelope, Connection, Dashboard), the Week 2 features B1, B2, I1, I2, F1 and (pending) F2, and the compliance and rate-limit rules that apply to them.

**Out of scope until their week:** Price check, Trade overlay and Session messages (drafts in PROTOCOL.md), the item parser and the `shared/samples/` fixtures (B3, PC-2; the folder is still empty), the trade search/fetch client (I3), hotkeys and game input (F4, F6).

**Test levels**

| Level | Tool | Where | Network |
|---|---|---|---|
| **BE** backend unit/integration | ExUnit | `backend/test/quicksilver/**` | None. `HTTP.Disabled` is the default adapter in the test env; integration tests replay `backend/test/fixtures/integrations/` through `test/support/integrations/fixture_http.ex`. Loopback sockets only. |
| **BE-e2e** backend end-to-end | ExUnit, tag `:e2e` | `backend/test/e2e/launch_e2e_test.exs` | Boots `mix run` with `QUICKSILVER_OFFLINE=1`; loopback only. |
| **FE** frontend unit | Qt Test via ctest, label `unit` | `frontend/tests/tst_*.cpp` | Fake WebSocket server on loopback. |
| **XP** cross-process e2e | Qt Test via ctest, label `integration` | `frontend/tests/tst_backend_e2e.cpp` | Starts the real backend (erl + mix, `QUICKSILVER_OFFLINE=1`); loopback only. |
| **M** manual | checklist in section 4 | this machine, Windows 11 | Cases marked *online* need the real internet. |
| **R** QA code review | grep/read | each review | n/a |

**Test file key** (used in the Status column)

| Key | File |
|---|---|
| `sock` | `backend/test/quicksilver/gateway/socket_test.exs` |
| `hs` | `backend/test/quicksilver/gateway/handshake_test.exs` |
| `env` | `backend/test/quicksilver/gateway/envelope_test.exs` |
| `orig` | `backend/test/quicksilver/gateway/origin_test.exs` |
| `dash` | `backend/test/quicksilver/gateway/dashboard_test.exs` |
| `endp` | `backend/test/quicksilver/gateway/endpoint_test.exs` |
| `app` | `backend/test/quicksilver/application_test.exs` |
| `hlth` | `backend/test/quicksilver/health_test.exs` |
| `launch` | `backend/test/quicksilver/launch_test.exs` |
| `stdin` | `backend/test/quicksilver/stdin_watcher_test.exs` |
| `sett` | `backend/test/quicksilver/settings_test.exs` |
| `http` | `backend/test/quicksilver/integrations/http_test.exs` |
| `rl` | `backend/test/quicksilver/integrations/rate_limiter_test.exs` |
| `ninja` | `backend/test/quicksilver/integrations/poe_ninja_test.exs` |
| `leag` | `backend/test/quicksilver/integrations/leagues_test.exs` |
| `pars` | `backend/test/quicksilver/integrations/parser_test.exs` |
| `integ` | `backend/test/quicksilver/integrations/integrations_test.exs` |
| `be-e2e` | `backend/test/e2e/launch_e2e_test.exs` |
| `codec` | `frontend/tests/tst_protocol_codec.cpp` |
| `client` | `frontend/tests/tst_protocol_client.cpp` |
| `loc` | `frontend/tests/tst_backend_locator.cpp` |
| `job` | `frontend/tests/tst_process_job.cpp` |
| `xp` | `frontend/tests/tst_backend_e2e.cpp` |

**Status values:** `covered` (file key + exact test name), `PARTIAL` (the missing part is stated), `GAP` (no automated test), `pending F2`, `N/A wk N` (feature not built yet), `review` (checked by QA code review only).

## 2. Protocol test cases

### 2.1 Launch and lifetime

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-LAUNCH-001 | CON-1 | Backend READY line is exactly `QUICKSILVER_READY {"port":N,"protocol_version":1}`, one line | BE | covered: `launch` "ready line is exactly the PROTOCOL format", "announce prints one line to the device" |
| TP-LAUNCH-002 | CON-1, NFR-SEC-1 | With `QUICKSILVER_PORT=0` the OS picks the port, the listener is on 127.0.0.1, READY carries that port; exactly one READY line on stdout | BE, BE-e2e | covered: `app` "listener is bound to 127.0.0.1 on an OS-chosen port, and the READY line uses it"; `be-e2e` "READY line, handshake, and exit on stdin close" |
| TP-LAUNCH-003 | NFR-SEC-1 | Listener refuses non-loopback addresses | BE, M | covered: `app` "the listener refuses non-loopback addresses"; M-15 |
| TP-LAUNCH-004 | CON-1, NFR-SEC-2 | Dev: no `QUICKSILVER_PORT` gives 47474; no token turns the token check off and logs a warning | BE | PARTIAL: `launch` "env: defaults to port 47474 and no token"; `hs` "token check is off when the backend has no token"; `sock` "with no token configured (dev), any token is accepted". The warning is not asserted |
| TP-LAUNCH-005 | CON-1 | Invalid `QUICKSILVER_PORT` is an error; explicit values honoured | BE | covered: `launch` "env: invalid ports are errors", "env: port 0 and explicit values" |
| TP-LAUNCH-006 | CON-1 | Backend exits when its stdin closes | BE, BE-e2e, XP | covered: `stdin` "calls on_eof once input ends, after consuming any lines"; `be-e2e` "READY line, handshake, and exit on stdin close"; `xp` `launch_connect_health_shutdown` |
| TP-LAUNCH-007 | CON-1 | `QUICKSILVER_EXIT_ON_STDIN_EOF=0` turns the stdin guard off | BE | covered: `launch` "env: stdin watch can be turned off for development"; `stdin` "is disabled by the launch flag" |
| TP-LAUNCH-008 | CON-1, NFR-MNT-2 | stdout carries **only** the READY line; all logs go to stderr | BE-e2e, R | PARTIAL: `be-e2e` counts one READY line but doesn't assert that no other stdout lines exist; logger→stderr is config only (`backend/config/config.exs`). Release build: B6 |
| TP-LAUNCH-009 | CON-1, CON-2 | Client parses READY: valid lines accepted, malformed rejected, another `protocol_version` reported at once | FE | covered: `codec` `ready_valid`, `ready_invalid`, `ready_otherVersionIsReported` |
| TP-LAUNCH-010 | NFR-SEC-2 | Client token: 32 hex chars from the OS RNG, new each launch | FE | covered: `codec` `token_is32HexAndRandom` |
| TP-LAUNCH-011 | CON-1, NFR-SEC-2 | Client starts the backend with `QUICKSILVER_PORT=0` and `QUICKSILVER_TOKEN`, and removes `QUICKSILVER_EXIT_ON_STDIN_EOF` | XP | PARTIAL: `xp` `handshakeRejections` proves the token reaches the backend; nothing tests that `EXIT_ON_STDIN_EOF` is stripped |
| TP-LAUNCH-012 | CON-1 | Client waits at most 20 s for READY, then shows "backend failed to start" | FE, M | GAP: the timeout path and its text are untested (tests only override `setReadyTimeoutMs`). Manual M-12 |
| TP-LAUNCH-013 | CON-1 | Client keeps draining stderr and non-READY stdout | XP | PARTIAL: `xp` `launch_connect_health_shutdown` finds backend stderr text in `recentLog()`; non-READY stdout lines untested |
| TP-LAUNCH-014 | CON-1 | Job Object with kill-on-close: child and grandchild die when the job closes | FE, M | covered: `job` `childIsResumedAndRuns`, `closingJob_killsChildAndGrandchild`, `terminate_endsJobNow`; M-01, M-03 |
| TP-LAUNCH-015 | CON-1 | Normal exit: close stdin, wait up to 3 s, then end the job; backend leaves through stdin EOF | FE, XP | covered: `job` `childStdin_closeIsEof`; `xp` `launch_connect_health_shutdown` (< 2.5 s, "stdin closed; shutting down" in the log) |
| TP-LAUNCH-016 | CON-1 | Locator never launches `.bat`/`.cmd` (no cmd.exe in between) | FE | covered: `loc` `explicit_batchFileRejected` |

### 2.2 Envelope

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-ENV-001 | NFR-MNT-2 | Server messages have exactly `type`, `id`, `ts` (UTC, ms, `Z`), `payload` (object) | BE | covered: `env` "produce type, id, ts (UTC ms, Z) and payload"; `sock` (`assert_envelope`) "valid hello gets welcome (echoing id) then an immediate health push" |
| TP-ENV-002 | NFR-MNT-2 | Client messages: same shape, `payload` always present, empty id sent as `null`, `ts` UTC ms `Z` | FE | covered: `codec` `encode_request`, `encode_emptyIdIsNullAndPayloadAlwaysPresent`, `timestamp_format` |
| TP-ENV-003 | NFR-MNT-2 | Client request ids are `"c-<n>"` | FE | covered: `client` `hello_carriesTokenVersionAndId` (hello is `c-1`), `requests_matchedById_outOfOrder` |
| TP-ENV-004 | CON-2 | Replies echo the request id; server pushes have id `null` | BE | covered: `sock` "valid hello gets welcome (echoing id) then an immediate health push"; `dash` "DASH-1: rates.subscribe replies rates.update echoing the id, per PROTOCOL", "DASH-1: a cache refresh is pushed as rates.update with id null" |
| TP-ENV-005 | NFR-MNT-2 | Receivers ignore unknown fields | BE, FE | covered: `env` "accepts a full envelope and ignores unknown fields"; `sock` "unknown envelope fields are ignored"; `codec` `decode_ignoresUnknownFieldsAndTs` |
| TP-ENV-006 | NFR-MNT-2 | An `id` that is neither string nor null is `bad_json`, answered with id `null` | BE | covered: `env` "errors keep a readable string id so the reply can echo it"; `sock` "valid JSON that isn't an envelope gets bad_json" (id 7) |
| TP-ENV-007 | NFR-MNT-2 | Invalid JSON, non-object, missing/mistyped `type` or `payload` → `bad_json`; connection stays open | BE | covered: `sock` "invalid JSON gets bad_json and the connection stays open", "valid JSON that isn't an envelope gets bad_json"; `env` "rejects non-JSON, non-objects and missing or mistyped type/payload" |
| TP-ENV-008 | NFR-MNT-2 | `bad_json` echoes the id when it can be read | BE | covered: `sock` "bad_json echoes the id when it can be read" |
| TP-ENV-009 | NFR-MNT-2 | `ts` is not validated or used by receivers | BE, FE | covered: `env` "accepts a full envelope and ignores unknown fields" (`ts:"x"`); `codec` `decode_ignoresUnknownFieldsAndTs` |
| TP-ENV-010 | NFR-MNT-2 | Binary frame after `hello` → `bad_json`, connection open | BE | covered: `sock` "a binary frame gets bad_json" |
| TP-ENV-011 | CON-2, NFR-SEC-2 | Binary frame **before** `hello` → `unauthorized`, close 1008 | BE | GAP: `backend/lib/quicksilver/gateway/socket.ex:81` is untested |
| TP-ENV-012 | NFR-MNT-2 | Unknown `type` → `unknown_type` echoing the id; connection stays open | BE, XP | covered: `sock` "unknown type gets unknown_type, echoing the id, and the connection stays open"; `xp` `launch_connect_health_shutdown` |
| TP-ENV-013 | NFR-MNT-2 | Client decoder accepts pushes and replies, rejects malformed envelopes | FE | covered: `codec` `decode_push`, `decode_reply`, `decode_invalid` |
| TP-ENV-014 | NFR-MNT-2 | Client treats a missing `id` as `null` | FE | covered: `codec` `decode_missingIdIsNull` |

### 2.3 Handshake

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-HS-001 | CON-2, CON-3 | Valid `hello` → `welcome` echoing the hello id, then one `health` at once | BE, BE-e2e, FE, XP | covered: `sock` "valid hello gets welcome (echoing id) then an immediate health push"; `be-e2e` "READY line, handshake, and exit on stdin close"; `client` `welcome_and_health`; `xp` `launch_connect_health_shutdown` |
| TP-HS-002 | CON-2 | `welcome` payload: `server_version`, `protocol_version` 1, `league`, `features.trade_api_enabled`, `health_interval_s` 5 | BE | covered: `sock` "valid hello gets welcome (echoing id) then an immediate health push", "welcome carries the active league and kill-switch setting" |
| TP-HS-003 | DASH-2 | `welcome.league` is the active league (= `leagues.result.current`) | BE | covered: `dash` "DASH-2: with nothing saved, it is the default league once the list is known" |
| TP-HS-004 | CON-2 | `welcome.league` is `null` with no league; client shows "not chosen yet" | BE, FE | covered: `dash` "with nothing saved and no list yet, it is null"; `client` `welcome_nullLeague` |
| TP-HS-005 | CON-2 | A stuck data source can't hold up `welcome` (null after 500 ms) | BE | covered: `dash` "a stuck data source can't hold up the handshake: welcome goes out with null" (behaviour is not written in PROTOCOL.md) |
| TP-HS-006 | CON-2, NFR-SEC-2 | No `hello` within 5 s → `unauthorized`, close 1008 | BE | covered: `sock` "no hello within the timeout gets unauthorized, then close" (100 ms); `endp` "gateway options default to the PROTOCOL values" (5 s default) |
| TP-HS-007 | CON-2 | The hello timer doesn't fire after a successful handshake | BE | covered: `sock` "the hello timeout does not fire after a successful handshake" |
| TP-HS-008 | CON-2, NFR-SEC-2 | Another type first → `unauthorized` echoing its id, close 1008 | BE | covered: `sock` "a message before hello gets unauthorized (echoing its id), then close" |
| TP-HS-009 | CON-2, NFR-SEC-2 | Invalid JSON first → `unauthorized`, close 1008 | BE | covered: `sock` "invalid JSON before hello gets unauthorized, then close" |
| TP-HS-010 | NFR-SEC-2 | Wrong, missing or non-string token → `unauthorized`, close 1008 | BE, XP | covered: `hs` "wrong, missing or non-string token is unauthorized"; `sock` "wrong token gets unauthorized, then the connection closes", "missing token gets unauthorized"; `xp` `handshakeRejections` |
| TP-HS-011 | CON-2 | Other integer `protocol_version` → `protocol_mismatch` with `expected: 1`, close 1008 | BE, XP | covered: `hs` "different integer version is protocol_mismatch with expected"; `sock` "different protocol_version gets protocol_mismatch with expected, then close"; `xp` `handshakeRejections` |
| TP-HS-012 | CON-2 | Missing/mistyped `protocol_version` or `client_version` → `bad_request`, close 1008 | BE | PARTIAL: `hs` "missing or non-integer fields are bad_request"; `sock` "hello with a non-integer protocol_version gets bad_request, then close". `client_version` only at unit level |
| TP-HS-013 | CON-2 | Check order step 1: `protocol_mismatch` wins over `bad_request` and `unauthorized` | BE | PARTIAL: `sock` "protocol_mismatch wins over a wrong token"; mismatch + bad `client_version` untested |
| TP-HS-014 | CON-2, NFR-SEC-2 | Check order step 2: `bad_request` wins over `unauthorized` | BE | GAP: no test sends a bad field together with a wrong token |
| TP-HS-015 | NFR-SEC-2 | Token is required only when the backend has one | BE | covered: `hs` "token check is off when the backend has no token"; `sock` "with no token configured (dev), any token is accepted" |
| TP-HS-016 | CON-2 | A second `hello` → `bad_request`, connection stays open | BE | covered: `sock` "a second hello gets bad_request and the connection stays open" |
| TP-HS-017 | NFR-SEC-1, NFR-SEC-2 | Upgrade with any `Origin` → HTTP 403, no WebSocket, also with no token | BE, XP | PARTIAL: `orig` "an upgrade with Origin: http://example.com gets 403 and no WebSocket", "an upgrade with Origin: null gets 403 and no WebSocket", "a refused upgrade never reaches the socket: no frames, no handshake", "Origin is refused even in dev mode (no token)"; `xp` `handshakeRejections`. Empty `Origin:` value untested |
| TP-HS-018 | NFR-SEC-1 | Plain `GET /ws` (no upgrade) **with** `Origin` → 403, body `Forbidden` | BE | GAP: `sock` "other paths are 404 and a plain GET /ws is 400" covers only the no-Origin case |
| TP-HS-019 | NFR-SEC-1 | Upgrade without `Origin` upgrades normally | BE | covered: `orig` "an upgrade without an Origin header upgrades normally" |
| TP-HS-020 | NFR-SEC-2 | Client's upgrade request has no `Origin` header | FE, XP | covered: `client` `upgradeRequest_hasNoOriginHeader`, `hello_carriesTokenVersionAndId`; `xp` `handshakeRejections` |
| TP-HS-021 | CON-2, NFR-SEC-2 | Client `hello` has `client_version`, integer `protocol_version` 1, `token`, id `c-n` | FE | covered: `codec` `hello_payload`; `client` `hello_carriesTokenVersionAndId` |
| TP-HS-022 | CON-2 | Client turns a handshake `error` + close into `handshakeFailed(code)` for `protocol_mismatch`, `unauthorized`, `bad_request` | FE | covered: `client` `handshake_rejected` (3 rows) |
| TP-HS-023 | CON-2 | Client shows "Backend and client versions don't match. Reinstall Quicksilver." on a mismatch (handshake or READY) | FE, M | GAP: `BackendConnection` status text is untested; M-11 |
| TP-HS-024 | CON-4 | Client gives up when no `welcome` arrives in time | FE | covered: `client` `handshakeTimeout_emitsClosed` |

### 2.4 Health

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-HLTH-001 | CON-3 | `health` once after `welcome`, then every `health_interval_s` | BE, FE, XP | covered: `sock` "repeats every interval in the PROTOCOL shape"; `client` `welcome_and_health`; `xp` `launch_connect_health_shutdown` |
| TP-HLTH-002 | CON-3, NFR-MNT-2 | Payload: `uptime_s`, `sources[]` with `name`, `status`, `last_success` (ms `Z` or null), `cache_age_s`, `detail`, `rate_limit` | BE | covered: `sock` "repeats every interval in the PROTOCOL shape"; `hlth` "payload formats timestamps and computes cache age" |
| TP-HLTH-003 | CON-3, DASH-3 | `poe_ninja` and `trade_leagues` start `idle`, in PROTOCOL order; later sources ordered by PROTOCOL | BE | covered: `sock` "lists the Week 2 sources as idle at startup, in order"; `hlth` "Week 2 sources start idle, in PROTOCOL order", "new sources are ordered by PROTOCOL, then by registration" |
| TP-HLTH-004 | DASH-3, NFR-REL-3 | `status` moves through `ok` / `degraded` / `down` with the source | BE | covered: `sock` "reflects reports from data sources"; `hlth` "status :ok sets last_success to now unless given", "report merges attributes and keeps the rest"; `ninja` "a failed refresh serves the cache marked stale (degraded)", "no cache and the source is down: unavailable, Health down"; `leag` "a failed refresh keeps serving the old list (degraded)", "no list and no saved league: Standard, Health down; then recovers" |
| TP-HLTH-005 | CON-3, NFR-API-1 | `rate_limit` wire shape `{policy, queued, restricted_until}` | BE | covered: `hlth` "rate_limit is exposed in wire shape"; `rl` "reports policy, queue length and restriction to Health" |
| TP-HLTH-006 | NFR-REL-1 | Health crash is restarted; connections keep getting `health` | BE | covered: `app` "Health crashing is restarted and connections keep receiving health" |
| TP-HLTH-007 | CON-3 | Bad reports don't break Health | BE | covered: `hlth` "invalid reports raise in the caller and don't touch the server", "report to a server that isn't running returns :ok" |
| TP-HLTH-008 | DASH-3 | Client shows the sources in the order given, with status and cache age | M | pending F2 (F2-03) |

### 2.5 Error codes

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-ERR-001 | NFR-MNT-2 | Only the 8 PROTOCOL codes can be sent | BE | covered: `env` "every PROTOCOL error code is accepted" (the encoder guards `code in @error_codes`) |
| TP-ERR-002 | NFR-MNT-2 | `bad_json` | BE | covered: see TP-ENV-006, 007, 010 |
| TP-ERR-003 | NFR-MNT-2 | `bad_request` for a missing or mistyped payload field | BE | covered: `dash` "bad_request for a missing, empty or mistyped league"; `sock` "dashboard types are routed, not unknown_type" |
| TP-ERR-004 | NFR-MNT-2 | `unknown_type` keeps the connection open | BE | covered: see TP-ENV-012 |
| TP-ERR-005 | NFR-SEC-2 | `unauthorized`, then close | BE | covered: see TP-HS-006, 008, 009, 010 |
| TP-ERR-006 | CON-2 | `protocol_mismatch`, then close | BE | covered: see TP-HS-011 |
| TP-ERR-007 | DASH-2 | `unknown_league` | BE | covered: `dash` "unknown_league for a league that isn't in the list; nothing is saved" |
| TP-ERR-008 | NFR-REL-3 | `upstream_unavailable` | BE | covered: `dash` "upstream_unavailable when the league list can't be fetched" (leagues.list and league.set) and the cases in 2.8, 2.9 |
| TP-ERR-009 | NFR-MNT-2 | `internal`: details stay in the backend log; connection stays open | BE | covered: `dash` "internal when the settings file can't be written", "a crashing job answers internal and the connection stays open" |
| TP-ERR-010 | NFR-UX-3 | Client acts on `code`, never `message`; reply errors go to the request's handler; error pushes reach `serverError` with the full payload | FE, R | covered: `client` `unknownIdReply_ignored_and_errorPush_reported`, `handshake_rejected`; review of `frontend/src/core/backend_connection.cpp:161-195` |

### 2.6 `leagues.list` → `leagues.result`

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-LGL-001 | DASH-2 | Reply `leagues.result` with `[{id, text}]`, `realm == "pc"` only, source order, plus `current` | BE | covered: `dash` "DASH-2: replies leagues.result with PC leagues in source order and the current league"; `pars` "trade leagues: PC only, source order, id + text"; `leag` "lists PC leagues in source order and defaults to the first one" |
| TP-LGL-002 | DASH-2 | Cold cache: waits for the first fetch, then answers | BE | covered: `dash` "on a cold cache, waits for the first fetch and answers" |
| TP-LGL-003 | NFR-REL-3 | List can't be fetched, or the fetch exceeds the upstream timeout → `upstream_unavailable` | BE | covered: `dash` "upstream_unavailable when the league list can't be fetched", "upstream_unavailable when the fetch takes longer than upstream_timeout_ms" |
| TP-LGL-004 | NFR-API-3 | List cached 1 h, no refetch inside the TTL, fetched at startup | BE | covered: `leag` "serves the cache within the TTL (one request)", "auto refresh fetches at startup" |
| TP-LGL-005 | DASH-2 | Default league: first PC league, else `Standard` | BE | covered: `leag` "lists PC leagues in source order and defaults to the first one", "no list and no saved league: Standard, Health down; then recovers" |
| TP-LGL-006 | DASH-2 | A saved league that ended falls back to the default without overwriting the setting | BE | covered: `leag` "a saved league that ended falls back to the default without overwriting it" |
| TP-LGL-007 | DASH-2 | Real PC league list matches the trade site (*online*) | M | M-05; selector pending F2 |

### 2.7 `league.set` → `league.changed`

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-LGS-001 | DASH-2 | Reply `league.changed {league}`; the league is saved and restored after a restart | BE | covered: `dash` "DASH-2: replies league.changed, saves the league, and it is restored after a restart"; `leag` "restores the saved league; set_current saves and broadcasts"; `sett` "round-trips through the file across restarts" |
| TP-LGS-002 | DASH-2 | Subscribed: a fresh `rates.update` follows `league.changed` (also for the same league) | BE | covered: `dash` "DASH-2: when subscribed, a fresh rates.update for the new league follows league.changed", "setting the same league again still pushes fresh rates (cached)" |
| TP-LGS-003 | DASH-2 | Not subscribed: nothing follows | BE | covered: `dash` "without a subscription no rates.update follows" |
| TP-LGS-004 | DASH-2 | League not in the list → `unknown_league`, nothing saved; ids case-sensitive | BE | covered: `dash` "unknown_league for a league that isn't in the list; nothing is saved", "league ids are matched exactly (case-sensitive)"; `leag` "rejects leagues that aren't listed (including other realms' only names)" |
| TP-LGS-005 | NFR-MNT-2 | Missing, empty or non-string `league` → `bad_request` | BE | covered: `dash` "bad_request for a missing, empty or mistyped league" |
| TP-LGS-006 | NFR-REL-3 | League list unavailable → `upstream_unavailable`, nothing saved | BE | PARTIAL: `dash` (describe "league.set") "upstream_unavailable when the league list can't be fetched" checks the code, not that nothing was saved |
| TP-LGS-007 | NFR-MNT-2 | Settings write fails → `internal`, reason not leaked | BE | covered: `dash` "internal when the settings file can't be written" |
| TP-LGS-008 | DASH-2 | Settings file is `settings.json` in `:filename.basedir(:user_config, "Quicksilver")` (`%APPDATA%\Quicksilver\`) | BE, M | covered: `sett` "the default directory is the OS user config dir unless overridden"; M-07 |
| TP-LGS-009 | DASH-2, NFR-REL-1 | Settings survive a corrupt file, keep unknown keys, write atomically | BE | covered: `sett` "a corrupt file is moved aside and defaults are used", "keeps unknown keys from the file", "writes leave no temp files and stale ones are cleaned at start", "creates the directory if missing", "a value that can't be encoded is refused and nothing changes" |

### 2.8 `rates.subscribe` / `rates.unsubscribe` / `rates.update`

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-RATES-001 | DASH-1 | `rates.subscribe` → `rates.update` echoing the id | BE | covered: `dash` "DASH-1: rates.subscribe replies rates.update echoing the id, per PROTOCOL" |
| TP-RATES-002 | DASH-1 | Each cache refresh → `rates.update` push with id `null` | BE | covered: `dash` "DASH-1: a cache refresh is pushed as rates.update with id null" |
| TP-RATES-003 | DASH-1 | Subscribing twice still gives one push per refresh | BE | covered: `dash` "subscribing twice still gives one push per refresh"; `integ` "subscribe is idempotent and messages arrive once" |
| TP-RATES-004 | DASH-1 | `rates.unsubscribe` → `rates.unsubscribed {}`, pushes stop; idempotent | BE | covered: `dash` "rates.unsubscribe replies rates.unsubscribed and stops the pushes", "rates.unsubscribe without a subscription still replies rates.unsubscribed" |
| TP-RATES-005 | DASH-1 | The subscription ends with the socket | BE | covered: `dash` "the subscription is removed when the socket closes" |
| TP-RATES-006 | NFR-REL-3 | No data and the source is down → `upstream_unavailable`; subscription stays; data is pushed when it arrives | BE | covered: `dash` "NFR-REL-3: upstream_unavailable when poe.ninja is down with nothing cached; the subscription stays and data is pushed once it arrives" |
| TP-RATES-007 | DASH-1 | Uncovered league, or no league yet → `upstream_unavailable` | BE | covered: `dash` "upstream_unavailable for a league poe.ninja doesn't cover", "upstream_unavailable when no league is known yet" |
| TP-RATES-008 | DASH-1 | The reply comes before any push; a held push identical to the reply isn't sent twice | BE | covered: `dash` "the reply comes before a refresh that arrives while it is being prepared", "a held refresh identical to the reply isn't sent twice" |
| TP-RATES-009 | DASH-1, NFR-MNT-2 | Payload: `league`, `source`, `fetched_at` (ms `Z`), `stale`, `divine_chaos`, `rates[]` rows with exactly `id, name, chaos, divine, change_7d, volume_chaos` (numbers; the last two may be null); no icon field | BE | covered: `dash` (`assert_rates_payload`) "DASH-1: rates.subscribe replies rates.update echoing the id, per PROTOCOL"; `ninja` "rates for the current league, shaped like rates.update" |
| TP-RATES-010 | DASH-1 | `chaos` = poe.ninja `primaryValue`; `divine` = `chaos / divine_chaos`; `divine_chaos` from the `divine` line, else `1 / core.rates.divine` | BE | covered: `pars` "exchange overview → rate rows", "exchange: divine rate falls back to core.rates when there is no divine line" |
| TP-RATES-011 | DASH-1 | Rows sorted by `chaos`, descending | BE | covered: `pars` "exchange overview → rate rows"; `dash` `assert_rates_payload` |
| TP-RATES-012 | NFR-REL-3 | A failed refresh with a cache → `stale: true` | BE | covered: `ninja` "a failed refresh serves the cache marked stale (degraded)"; `dash` "DASH-1: a cache refresh is pushed as rates.update with id null" |
| TP-RATES-013 | DASH-1 | `change_7d` / `volume_chaos` are `null` when the source line has no `sparkline` / volume | BE | PARTIAL: the payload check allows null, but no parser test feeds a line without `sparkline` or `volumePrimaryValue` |
| TP-RATES-014 | NFR-API-3 | poe.ninja TTL = `max-age − Age`, fallback 30 min, floor 60 s; refetch only after it | BE | covered: `http` "freshness is max-age minus Age, with fallback and floor", "recorded poe.ninja headers"; `ninja` "fetches index-state, Currency and the item category once, then serves from cache", "refetches once the header TTL (max-age - Age) has passed" |
| TP-RATES-015 | DASH-1 | Empty `lines` means unsupported type, not "no prices" | BE | covered: `pars` "empty lines mean an unsupported type, not 'no prices'"; `ninja` "empty lines are treated as an unsupported type, not as no prices" |
| TP-RATES-016 | DASH-1 | Leagues missing from index-state are never requested | BE | covered: `ninja` "leagues poe.ninja doesn't cover are never requested" |
| TP-RATES-017 | DASH-2 | A league change pushes cached rates at once and fetches a new league | BE | covered: `ninja` "a league change pushes cached rates at once; a new league is fetched" |
| TP-RATES-018 | DASH-1 | League names with spaces are encoded as `%20` | BE | covered: `ninja` "space in league names is encoded as %20" |
| TP-RATES-019 | DASH-1 | Rates table matches poe.ninja within one refresh (*online*) | M | pending F2 (F2-01, M-06) |

### 2.9 Rates error push

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-RERR-001 | DASH-2 | Subscribed, `league.set` to an uncovered league → after `league.changed`: `error`, id `null`, `code: upstream_unavailable`, `topic: "rates"`, `league` | BE | covered: `dash` "DASH-2: league.set to a league poe.ninja doesn't cover pushes it after league.changed" |
| TP-RERR-002 | NFR-REL-3 | A failed fetch for the new league with nothing cached → pushed | BE | covered: `dash` "NFR-REL-3: a failed fetch for the new league with nothing cached pushes it" |
| TP-RERR-003 | DASH-2 | Not repeated for the same league | BE | covered: `dash` "setting the same uncovered league again doesn't repeat it" |
| TP-RERR-004 | DASH-2 | Not pushed without a rates subscription | BE | covered: `dash` "not pushed without a rates subscription" |
| TP-RERR-005 | DASH-2 | A league the backend picks itself is checked too | BE | covered: `dash` "a league the backend picks itself (fallback) is checked too" |
| TP-RERR-006 | DASH-2 | Dropped if the league changes again before the check finishes | BE | covered: `dash` "dropped if the league changed again before the check finished" |
| TP-RERR-007 | DASH-1 | After the error push the subscription stays, and a later `rates.update` for that league is delivered | BE | PARTIAL: shown for the subscribe-time error (TP-RATES-006), not after a rates error push |
| TP-RERR-008 | DASH-1 | Client receives the push with `topic` and `league` intact | FE | covered: `client` `unknownIdReply_ignored_and_errorPush_reported` |
| TP-RERR-009 | DASH-1, NFR-UX-3 | Client clears the rates table and shows the message | M | pending F2 (F2-04) |

### 2.10 Out-of-order replies and concurrency

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-ORD-001 | NFR-MNT-2 | A slow `leagues.list` doesn't block `health` or other requests | BE | covered: `dash` "a slow leagues.list doesn't block health pushes or other requests" |
| TP-ORD-002 | NFR-MNT-2 | A slow `rates.subscribe` doesn't block `leagues.list` (replies out of order) | BE | covered: `dash` "a slow rates.subscribe doesn't block leagues.list" |
| TP-ORD-003 | NFR-MNT-2 | Client matches replies by id, not order; unknown-id replies are ignored | FE | covered: `client` `requests_matchedById_outOfOrder`, `unknownIdReply_ignored_and_errorPush_reported` |
| TP-ORD-004 | NFR-REL-1 | Jobs still running when the socket closes are stopped | BE | covered: `dash` "jobs still running when the socket closes are stopped" |
| TP-ORD-005 | CON-4 | Client fails pending requests on close; a request before `ready` fails asynchronously | FE | covered: `client` `serverClose_failsPendingAndEmitsClosed`, `request_beforeReady_failsAsync`, `close_isSilent` |

### 2.11 Connection lifecycle and reliability

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-CON-001 | CON-4 | Backend killed → client shows Disconnected → backend restarted → reconnected within 5 s of the restart | XP, M | covered: `xp` `killedBackend_isRestartedAndReconnected`; M-04 |
| TP-CON-002 | NFR-REL-1 | A crashing connection doesn't affect another | BE | covered: `app` "a crashing connection doesn't affect another connection" |
| TP-CON-003 | CON-4, NFR-REL-1 | A crashed listener is restarted on the same port | BE | covered: `endp` "a crashed listener is restarted on the same port" |
| TP-CON-004 | CON-1 | Supervision tree has the expected children; integrations subtree in order | BE | covered: `app` "supervision tree is up with the expected children"; `integ` "the subtree runs under the application, in order, and never fetches in tests" |
| TP-CON-005 | CON-4 | Client: refused connect → `closed` | FE | covered: `client` `connectRefused_emitsClosed` |
| TP-CON-006 | CON-4 | Retry policy: reconnect 0.5/1/2/4/5 s then restart; restart 1/2/4/8/15 s, give up after 5; no retry on `protocol_mismatch`, `unauthorized`, `bad_request`, READY timeout | FE | GAP: no `BackendConnection` unit test with a fake process; only the happy restart path in `xp` |

## 3. Compliance and rate-limit cases

| Case | Req | What's checked | Level | Status |
|---|---|---|---|---|
| TP-CMP-001 | NFR-API-2 | No external HTTP outside `backend/lib/quicksilver/integrations/http*`: only `MintAdapter` calls `Mint.HTTP`; only `Leagues` and `PoeNinja` call `HTTP.get_json/2` | R | review (2026-11-21: PASS). No automated guard |
| TP-CMP-002 | NFR-API-2, NFR-PRV-1 | Frontend makes no external calls: no `QNetworkAccessManager`, no `QTcpSocket`/`QSslSocket`, no non-loopback URL in `frontend/src` | R | review (2026-11-21: PASS). No automated guard |
| TP-CMP-003 | NFR-CMP-1 | No game-memory reads, injection, hooks, packet inspection or input APIs (`ReadProcessMemory`, `SetWindowsHookEx`, `SendInput`, `keybd_event`); `OpenProcess` only on our own backend child | R | review (2026-11-21: PASS; `frontend/src/platform/process_job_win.cpp:103`) |
| TP-CMP-004 | NFR-CMP-1, PC-1, TR-5 | At most one game action per keypress or click; no timer- or log-triggered input | R, M | N/A wk 3-4 (F4, F6): no input code yet |
| TP-CMP-005 | NFR-CMP-1 | GGG notice in the README and the About screen (installer: F7) | R, M | review: `README.md:34`, `frontend/src/ui/command_center_window.cpp:185`; M-13. Installer N/A wk 4 |
| TP-CMP-006 | NFR-CMP-2 | No PoE Overlay code, layout, icons or wording | R | review before release |
| TP-CMP-007 | NFR-PRV-1 | Only documented hosts (`www.pathofexile.com`, `poe.ninja`); no telemetry | R, M | review of `Quicksilver.Integrations.Urls` (PASS); network capture during the soak (wk 4) |
| TP-API-001 | NFR-API-2 | Exact User-Agent `Quicksilver/<ver> (contact: https://github.com/dxu13UW/Quicksilver)`, plus `accept: application/json` and `accept-encoding: gzip`, on every request | BE | covered: `http` "sends the project User-Agent, JSON accept and gzip on every request" |
| TP-API-002 | NFR-API-1 | GGG `x-rate-limit-*` headers parsed; no hardcoded limits | BE, R | covered: `rl` "parses GGG headers"; review of `rate_limiter.ex` (the only constants are the 500 ms margin and the 60 s header-less 429 back-off, both from DATA_SOURCES.md) |
| TP-API-003 | NFR-API-1 | Cold start and header-less hosts: one request in flight per bucket | BE | covered: `rl` "cold start: one request in flight per bucket until headers are seen" |
| TP-API-004 | NFR-API-1 | A full tier queues requests (never drops) until the window moves, plus 500 ms | BE | covered: `rl` "queues when a learned tier is full, and sends when the window moves" |
| TP-API-005 | NFR-API-1 | Resync from `-State` when the server counts more hits | BE | covered: `rl` "resyncs from the -State header when the server counts more hits" |
| TP-API-006 | NFR-API-1 | Buckets that share a policy share its budget | BE | covered: `rl` "buckets that share a policy share its budget" |
| TP-API-007 | NFR-API-1 | An active restriction pauses the policy | BE | covered: `rl` "an active restriction pauses the policy for its duration" |
| TP-API-008 | NFR-API-1 | 429 pauses for `max(Retry-After, restriction)` | BE | covered: `rl` "429 pauses for max(Retry-After, active restriction), then resumes" |
| TP-API-009 | NFR-API-1 | 429 with no headers pauses for the fallback back-off (60 s) | BE | covered: `rl` "429 without any headers pauses the bucket for the fallback back-off" |
| TP-API-010 | NFR-API-1 | A slot is released if the caller dies or the adapter raises | BE | covered: `rl` "a caller that dies while holding a slot releases it"; `http` "an adapter that raises releases its rate-limit slot" |
| TP-API-011 | NFR-MNT-1 | Tests never reach the network: `HTTP.Disabled` is the test-env default, unknown fixture URLs are refused, e2e boots set `QUICKSILVER_OFFLINE=1` | BE, XP, M | covered: `http` "the Disabled adapter refuses, and is the default in the test env", "an unknown URL never reaches the network in tests"; `integ` "the subtree runs under the application, in order, and never fetches in tests"; review of `be-e2e` and `xp` env; M-17 |
| TP-API-012 | NFR-API-1 (COMPLIANCE: avoid 4xx) | Failed fetches back off instead of hammering | BE | PARTIAL: `leag` "a failed attempt backs off instead of retrying on every call"; no named test for the poe.ninja back-off (60 s doubling to 30 min) |
| TP-API-013 | NFR-API-4 | No trade search/fetch exists or runs in the background | R | N/A wk 3 (I3). Week 2 review: no trade search/fetch URL in `urls.ex` |
| TP-API-014 | NFR-API-2 | gzip bodies decoded; `br` never offered | BE | covered: `http` "un-gzips gzip bodies", "sends the project User-Agent, JSON accept and gzip on every request" |
| TP-API-015 | NFR-API-2 | TLS uses `verify: :verify_peer` with the OS CA store | R | review of `integrations/http/mint_adapter.ex`; no automated test |
| TP-API-016 | NFR-API-1 | Non-2xx, transport and decode failures become errors | BE | covered: `http` "non-2xx, transport and decode failures are errors with a short description" |

## 4. Manual checklist

Run on Windows 11 with a fresh `frontend/build.bat` build. Record the date, result and notes in LOG.md.

| ID | Req | Steps | Pass when |
|---|---|---|---|
| M-01 | CON-1 | Start `Quicksilver.exe`, wait for Connected, then `taskkill /F /IM Quicksilver.exe` | No `erl.exe` remains in Task Manager (Job Object kill) |
| M-02 | CON-1 | Start, then close the window normally | Backend exits within 3 s; `backend.log` ends with "stdin closed; shutting down"; no `erl.exe` left |
| M-03 | CON-1 | Start under a debugger, then stop the debugger (hard crash) | No `erl.exe` remains |
| M-04 | CON-4 | Kill `erl.exe` from Task Manager | Status shows Disconnected, then Connected within 5 s of the new READY |
| M-05 | DASH-2 | *online* Start with network; view the league list (F1: health tree/log; F2: selector) | Same PC leagues, in the same order, as the trade site; current league is the challenge league or the saved one |
| M-06 | DASH-1 | *online* Compare 5 rows with poe.ninja | Values match within one refresh cycle (pending F2) |
| M-07 | DASH-2 | Choose a league, quit, restart | Same league selected; `%APPDATA%\Quicksilver\settings.json` holds it (pending F2) |
| M-08 | DASH-3 | *online* After the first load, disconnect the network | `poe_ninja` / `trade_leagues` turn degraded or down within one health cycle (F1 raw tree now; F2 panel pending) |
| M-09 | NFR-REL-3 | Go offline after the first load | Rates stay visible, marked stale with their age (pending F2) |
| M-10 | DASH-2 | Select a Ruthless league while viewing rates | Table clears; "poe.ninja has no prices for this league." is shown (pending F2) |
| M-11 | CON-2 | Force a version mismatch: point `QUICKSILVER_BACKEND_EXE` at a stub exe that prints a READY line with `protocol_version` 2 | Status shows "Backend and client versions don't match. Reinstall Quicksilver." with no automatic retry |
| M-12 | CON-1 | Set `QUICKSILVER_READY_TIMEOUT_S=1` and start | Status "Backend failed to start" with a Restart button; Restart works after unsetting it |
| M-13 | NFR-CMP-1 | Help → About | Shows "This product isn't affiliated with or endorsed by Grinding Gear Games in any way." |
| M-14 | NFR-SEC-1 | In a browser console: `new WebSocket("ws://127.0.0.1:<port>/ws")` | Fails (HTTP 403) |
| M-15 | NFR-SEC-1 | From another machine on the LAN, connect to the port | Connection refused |
| M-16 | CON-1 | Look in `%LOCALAPPDATA%\Quicksilver\logs\` | `backend.log` and `client.log` exist and grow |
| M-17 | NFR-MNT-1 | Disable the network adapter; run `mix test --include e2e` and `ctest` | All pass |
| M-18 | NFR-PERF-4 | Leave the app idle for 30 min | Backend and client each < 150 MB (target) |
| M-19 | CON-1, CON-4 | Walk the UI states | Starting backend → Connecting → Connected; Disconnected after a kill; Failed with a Restart button on fatal errors; a null `welcome.league` shows "not chosen yet" |

**Pending F2 (dashboard): run when F2 lands**

| ID | Req | Check |
|---|---|---|
| F2-01 | DASH-1 | Rates table shows name, chaos, divine, 7-day change and volume, sorted by chaos, with "last updated" from `fetched_at` |
| F2-02 | DASH-2 | League selector lists `leagues.result` in order; choosing one sends `league.set`; `unknown_league` / `upstream_unavailable` are shown in plain language |
| F2-03 | DASH-3 | Health panel lists the sources in the order given, with status (idle/ok/degraded/down), cache age and rate-limit state |
| F2-04 | DASH-1 | The rates error push (`topic: "rates"`) clears the table and shows the message; a later `rates.update` replaces it |
| F2-05 | NFR-REL-3 | `stale: true` shows a stale marker with the data's age |
| F2-06 | NFR-MNT-2 | F2 code matches replies by id, branches on `code` (never `message`), ignores unknown fields |

## 5. How to run

All commands are for Git Bash on this machine.

**Backend (ExUnit)**
```bash
cd /c/dev/Quicksilver/backend
mix test                     # unit + integration, offline; e2e excluded
mix test --include e2e       # adds test/e2e/launch_e2e_test.exs (boots mix run with QUICKSILVER_OFFLINE=1)
mix test test/quicksilver/gateway/socket_test.exs    # one file
```

**Frontend (Qt Test through ctest)**
```bash
cmd //d //c "C:\dev\Quicksilver\frontend\build.bat"         # configure + build + every ctest program, incl. the real-backend e2e
cmd //d //c "C:\dev\Quicksilver\frontend\build.bat" clean   # same, from an empty build/
ctest --test-dir /c/dev/Quicksilver/frontend/build -LE integration --output-on-failure   # unit tests only (skips tst_backend_e2e)
```
- Each ctest program prepends the Qt `bin` folder to `PATH` and sets `QT_QPA_PLATFORM=offscreen`, so `ctest` runs from Git Bash once the build exists.
- Qt Test console output can vanish under Git Bash. For per-case results, run an exe directly with `-o out.txt,txt` (with `C:\Qt\6.8.3\msvc2022_64\bin` on `PATH` and `QT_QPA_PLATFORM=offscreen`).
- Run the backend and frontend suites one after the other, not at the same time: both boot real backends.

**Results on record**

| Date | Commit | Backend | Frontend |
|---|---|---|---|
| 2026-11-21 (Q1) | `fc06e93` | `mix test --include e2e`: 155 tests, 0 failures | 5/5 ctest programs passed; 81 Qt Test functions (codec 42, client 16, locator 11, job 7, e2e 5), 0 skipped |

## 6. Coverage summary (2026-11-21)

| Section | Cases | Covered | Partial | Gap | Pending F2 | N/A | Review only |
|---|---|---|---|---|---|---|---|
| 2.1 Launch and lifetime | 16 | 11 | 4 | 1 | 0 | 0 | 0 |
| 2.2 Envelope | 14 | 13 | 0 | 1 | 0 | 0 | 0 |
| 2.3 Handshake | 24 | 18 | 3 | 3 | 0 | 0 | 0 |
| 2.4 Health | 8 | 7 | 0 | 0 | 1 | 0 | 0 |
| 2.5 Error codes | 10 | 10 | 0 | 0 | 0 | 0 | 0 |
| 2.6 leagues.list | 7 | 6 | 0 | 0 | 1 | 0 | 0 |
| 2.7 league.set | 9 | 8 | 1 | 0 | 0 | 0 | 0 |
| 2.8 rates | 19 | 17 | 1 | 0 | 1 | 0 | 0 |
| 2.9 Rates error push | 9 | 7 | 1 | 0 | 1 | 0 | 0 |
| 2.10 Out of order | 5 | 5 | 0 | 0 | 0 | 0 | 0 |
| 2.11 Lifecycle | 6 | 5 | 0 | 1 | 0 | 0 | 0 |
| 3 Compliance and rate limits | 23 | 13 | 1 | 0 | 0 | 2 | 7 |
| **Total** | **150** | **120** | **11** | **6** | **4** | **2** | **7** |

**Gaps worth closing first** (owner agent in brackets)
1. TP-HS-014, TP-HS-013: handshake check order with combined faults (bad field + wrong token; mismatch + bad `client_version`). [backend]
2. TP-ENV-011: binary frame before `hello` → `unauthorized` + 1008. [backend]
3. TP-HS-018, TP-HS-017: plain `GET /ws` with `Origin` → 403 `Forbidden`; empty `Origin:` value. [backend]
4. TP-CON-006, TP-HS-023, TP-LAUNCH-012: `BackendConnection` tests with a fake process for the retry policy, the mismatch text and the READY timeout. [frontend]
5. TP-LAUNCH-011, TP-LAUNCH-013: `QUICKSILVER_EXIT_ON_STDIN_EOF` is stripped; non-READY stdout is drained. [frontend]
6. TP-CMP-001, TP-CMP-002: an automated guard that fails when an HTTP client appears outside the allowed modules (backend `lib/`, `frontend/src`). [backend, frontend]
7. TP-RATES-013, TP-API-012: parser null path for `change_7d`/`volume_chaos`; a poe.ninja back-off test. [integrations]
