# Protocol (v1)

The only interface between the C++ client and the Elixir backend.
- **Transport:** WebSocket at `ws://127.0.0.1:<port>/ws`. Text frames carry one JSON object each.
- **`protocol_version`:** `1`. It's an integer.
- **Change rule:** edit this file first, bump `protocol_version`, then update both sides. QA checks both against this file.
- **Status:** the Connection and Dashboard sections are **final for v1** (Week 2). Price check, Trade overlay and Session are still drafts; they get exact payloads in the week they're built.

## Launch and lifetime
**Production (the client starts the backend)**
1. The client creates a random token (32 hex chars). It starts the backend with these environment variables:
   - `QUICKSILVER_PORT=0`, so the OS picks a free port.
   - `QUICKSILVER_TOKEN=<token>`.
2. The backend binds `127.0.0.1` only. When it's ready, it writes **exactly one line** to stdout:
   `QUICKSILVER_READY {"port":53123,"protocol_version":1}`
   The client reads stdout until it sees that line, waiting at most **20 s**. If it times out, it shows "backend failed to start".
3. **Cleanup:**
   - The client puts the backend process in a Windows **Job Object** with *kill-on-job-close*. That way the OS ends the backend even if the client crashes (REQUIREMENTS CON-1).
   - The backend also exits when its stdin closes, as a best-effort second guard.
   - On a normal exit, the client closes the backend's stdin and waits up to 3 s before ending the job.

**Development (backend run by hand with `mix run --no-halt`)**
- Port: `QUICKSILVER_PORT` if set; otherwise **47474**.
- Token: if `QUICKSILVER_TOKEN` isn't set, the token check is off and a warning is logged. The production client always sets it.
- The backend still prints the `QUICKSILVER_READY` line.
- `QUICKSILVER_EXIT_ON_STDIN_EOF=0` (dev only) turns off the stdin guard, for running the backend in the background with no stdin. The production client never sets it.

**Output streams:**
- stdout carries **only** the READY line.
- All logs go to stderr.
- The client must keep reading (or discarding) **both** streams. A full pipe would block the backend.

## Envelope
Every message has the same outer shape:
```json
{"type": "rates.update", "id": "c-12", "ts": "2026-11-19T21:04:05.123Z", "payload": {}}
```
- `type`: message name.
- `id`: string or `null`.
  - **Requests:** the sender picks the id. The client uses `"c-<n>"`.
  - **Replies:** echo the request's id.
  - **Server pushes:** `null`.
- `ts`: UTC, ISO-8601 with milliseconds and a `Z` suffix.
- `payload`: an object, always present (it may be empty: `{}`).

Rules:
- A receiver ignores fields it doesn't recognise. This lets new fields be added without breaking anything.
- An `id` that is neither a string nor `null` is `bad_json`, and the error goes back with id `null`.
- `ts` is informational. Receivers don't validate it or rely on it, so clock differences don't matter.
- Binary frames are `bad_json`, or `unauthorized` before `hello`.
- For an unknown `type`, the server replies with error `unknown_type` and **keeps the connection open**.
- Replies can arrive in a different order from the requests: a slow upstream call doesn't hold up later requests. The client matches replies to requests by `id`, never by order.

## Connection

### Handshake
- The client's first message must be `hello`, sent within **5 s** of connecting.
- Otherwise, or if the first message is anything else, the server sends error `unauthorized` and closes the connection.

**`hello`** (c→s)
```json
{"client_version": "0.1.0", "protocol_version": 1, "token": "9f2c…"}
```
**`welcome`** (s→c, echoes the hello's id)
```json
{"server_version": "0.1.0", "protocol_version": 1, "league": "Covens",
 "features": {"trade_api_enabled": true}, "health_interval_s": 5}
```
- `league` is the **active** league, the same value as `leagues.result.current`. That is the saved league, or the default league when none is saved or the saved one has ended. It's `null` if the backend has no league yet, or if the league can't be read within 500 ms (the handshake is never delayed for it). The client then learns the league from `leagues.list`. (Decided 2026-11-19; it was "the saved league".)
- `health_interval_s` is a number of seconds (5 in production; tests may use fractions).
- **Wrong token** → error `unauthorized`, then the server closes the connection.
- **Different `protocol_version`** → error `protocol_mismatch`, with `"expected": 1` in the payload, then the server closes the connection.
  - The client shows: "Backend and client versions don't match. Reinstall Quicksilver."

**Handshake rules in detail** (decided 2026-11-19)
- **Required `hello` fields:**
  - `protocol_version` (integer) and `client_version` (string), always.
  - `token` (string), whenever the backend has one.
- **Check order:**
  1. `protocol_mismatch`, so a client on another version always gets the "reinstall" message.
  2. `bad_request`, for a missing or mistyped field.
  3. `unauthorized`.

  Every handshake failure sends the error, then closes the connection with WebSocket close code **1008** (policy violation).
- **Anything before `hello`** gets `unauthorized`, then the connection closes. That includes invalid JSON, a binary frame, any other type, and a `hello` frame that isn't a valid envelope (for example no `payload` object, or an `id` that's neither a string nor `null`). `bad_request` is only for a valid `hello` envelope whose payload fields are missing or mistyped.
- **A second `hello`** after the handshake gets `bad_request`. The connection stays open.
- **Origin check:** an upgrade request that carries an `Origin` header is refused with HTTP 403.
  - Browsers always send `Origin`, and the Qt client doesn't, so this stops web pages from connecting to the backend, even in dev mode where there's no token.
  - The client must create its `QWebSocket` with an empty origin. Confirm this in F1.
  - Any `Origin` value counts, including `null` and an empty one. The check runs before upgrade validation, so a plain `GET /ws` with `Origin` also gets 403 (body `Forbidden`).

### `health` (s→c push)
Sent once right after `welcome`, then every `health_interval_s` seconds.
```json
{"uptime_s": 123,
 "sources": [
   {"name": "poe_ninja", "status": "ok", "last_success": "2026-11-19T21:00:00.000Z",
    "cache_age_s": 245, "detail": null, "rate_limit": null},
   {"name": "trade_api", "status": "idle", "last_success": null,
    "cache_age_s": null, "detail": null,
    "rate_limit": {"policy": "trade-search-request-limit", "queued": 0, "restricted_until": null}}
 ]}
```
`status` takes one of these values:

| `status` | Meaning |
|---|---|
| `idle` | Not used yet in this run |
| `ok` | The last request succeeded |
| `degraded` | The last request failed, but cached data is still being served (marked stale) |
| `down` | Requests are failing and there is no usable cache |

Source names:
- `poe_ninja` (Week 2)
- `trade_leagues`, the trade league list (Week 2)
- `trade_api` (Week 3)
- `client_log` (Week 4)

The client shows the sources in the order given.

### `error` (either direction)
Echoes the `id` of the message that caused it, or `null`.
```json
{"code": "unknown_league", "message": "League 'Foo' isn't available."}
```
| Code | When |
|---|---|
| `bad_json` | The frame isn't valid JSON, or isn't an object with `type` and `payload` |
| `bad_request` | A required payload field is missing or has the wrong type |
| `unknown_type` | The `type` isn't known (the connection stays open) |
| `unauthorized` | Bad or missing token, or a message sent before `hello` (then the connection closes) |
| `protocol_mismatch` | Versions differ (then the connection closes) |
| `unknown_league` | The league isn't in the current league list |
| `upstream_unavailable` | A data source can't be reached and there's no cached data to answer with |
| `internal` | A bug in the backend. Its details go to the backend log, not to the client. |

`message` is plain language for display. The client decides what to do based on `code`, never `message`.

## Dashboard

### `leagues.list` (c→s) → `leagues.result` (s→c)
- Request payload: `{}`.
- Reply:
```json
{"leagues": [{"id": "Covens", "text": "Covens"}, {"id": "Standard", "text": "Standard"}],
 "current": "Covens"}
```
- Leagues come from the trade league list, filtered to `realm == "pc"` and kept in source order (ADR-004, DATA_SOURCES).
- `current` is the active league, or `null`.

### `league.set` (c→s) → `league.changed` (s→c)
- Request payload: `{"league": "Covens"}`.
- Reply: `{"league": "Covens"}`.
- The backend saves the league to its settings file and restores it on the next launch (DASH-2).
- If the client is subscribed to rates, a fresh `rates.update` push follows.
- A league that isn't in the list gets error `unknown_league`.
- If the league list can't be fetched (nothing cached and the source is down), the league can't be checked, so the reply is error `upstream_unavailable` and nothing is saved.
- If the client is subscribed and the server has no rates for the new league (poe.ninja doesn't cover it, e.g. Ruthless, or the fetch fails with nothing cached), it pushes the rates error described under `rates.subscribe` instead of a `rates.update`.

**Default league:** if none is saved, the backend uses the first PC league in the list (the current challenge league), or `Standard` if the list can't be fetched.

**`league.changed` push** (decided 2026-11-21): whenever the active league changes without a `league.set` from this client (a default chosen on first run, a replacement for an ended league, or the `Standard` fallback), the server pushes `league.changed` with id `null` and payload `{"league": "<id>"}` to every connected client. A client that already showed that league can ignore it. Rates for the new league follow as usual for subscribed clients.

**Settings file:** `settings.json` in `:filename.basedir(:user_config, "Quicksilver")`. That is `%APPDATA%\Quicksilver\` on Windows and `~/.config/Quicksilver/` on Linux.

### `rates.subscribe` / `rates.unsubscribe` (c→s)
- Payload: `{}`.
- **Subscribe:** the server replies with a `rates.update` that echoes the id. After that it pushes a `rates.update` (id `null`) whenever the cache refreshes or the league changes.
- On a cold start the reply waits (up to the upstream timeout) for the backend to choose a league and fetch its rates. "No league chosen yet" alone is never answered with an error.
- **Unsubscribe:** the server replies with `rates.unsubscribed` (payload `{}`) and stops the pushes. A `rates.subscribe` reply that was already pending is still sent.
- If there's no data yet and the source is down, the server sends error `upstream_unavailable` instead. The subscription stays active, and data is pushed once it arrives. This error is a reply (it echoes the subscribe's id and has no `topic`). The rates error push below is different: id `null`, with `topic` and `league`.
- `league.set` to the league that's already active still triggers a fresh `rates.update` (or rates error push) for subscribed clients.
- **Rates error push** (decided 2026-11-19): when a subscribed client's league changes and there are no rates for the new league, the server pushes error `upstream_unavailable` with id `null` and two extra payload fields, `"topic": "rates"` and the `"league"` it applies to:
  ```json
  {"code": "upstream_unavailable", "message": "poe.ninja has no prices for this league.", "topic": "rates", "league": "Ruthless Covens"}
  ```
  The client clears the rates table and shows the message. A later `rates.update` for that league replaces it. The subscription stays active.

### `rates.update` (s→c)
```json
{"league": "Covens", "source": "poe_ninja", "fetched_at": "2026-11-19T21:00:00.000Z",
 "stale": false, "divine_chaos": 145.7,
 "rates": [
   {"id": "divine", "name": "Divine Orb", "chaos": 145.7, "divine": 1.0,
    "change_7d": -2.1, "volume_chaos": 120345.6}
 ]}
```
- Values are numbers.
  - `chaos` is the poe.ninja `primaryValue`.
  - `divine = chaos / divine_chaos`.
  - `change_7d` (sparkline total change, in percent) and `volume_chaos` may be `null`.
- `stale: true` means the fetch failed and this is cached data. The client shows its age (NFR-REL-3).
- Rows are sorted by `chaos`, descending.
- **No icons in v1.** The client can't download them (the frontend never calls external services). If icons are added later, the backend will serve them.

## Price check (draft, finalised in Week 3)
| Type | Direction | Purpose |
|---|---|---|
| `price.request` | c→s | Raw clipboard item text |
| `price.result` | s→c | Parsed item summary, estimate (low/median/high in chaos and divines), source, confidence, listing count, and (for rares with the kill switch off) a trade-site URL |
| `price.pending` | s→c | Sent when a trade API request is queued behind a rate limit |

## Trade overlay (draft, finalised in Week 4)
| Type | Direction | Purpose |
|---|---|---|
| `trade.incoming` | s→c (push) | Buyer, item, price, stash tab name, left/top position, league |
| `trade.dismiss` | c→s | User closed a request |

## Session (draft, later)
| Type | Direction | Purpose |
|---|---|---|
| `session.update` | s→c (push) | Current zone, time in zone, maps run today |

## Open points
- Whether quick-reply text is built by the client or the server. Either way, the **user** presses the key that sends it (one action per keypress).
