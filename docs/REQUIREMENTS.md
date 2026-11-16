# Requirements (draft v0.1)

Defines **what "done" means** for Quicksilver. Each requirement has an ID, a priority, the PLAN item that delivers it, and a pass/fail check.
- QA tests against these IDs, and `docs/TEST_PLAN.md` refers to them.
- This file covers *what*, not *how*. Design lives in ARCHITECTURE.md, message formats in PROTOCOL.md, external APIs in DATA_SOURCES.md, and game rules in COMPLIANCE.md. Point to those files; don't repeat them here.
- **Change rule:** when you change a requirement, edit it here, note it in LOG.md, and update the affected PLAN item.

**Priority key**
- **M** = Must, for v0.1 at show and tell (Dec 7)
- **S** = Should, for v0.2 by final submission (Dec 13)
- **C** = Could, stretch

Numbers marked *(target)* are first guesses. Confirm or adjust them once something runs.

---

## 1. Scope

**In scope**
- Path of Exile 1 on Windows 10/11 x64, PC realm, Steam or standalone client.
- Features, in priority order: dashboard → price check → stash trade overlay → session summary.

**Out of scope for v0.1 and v0.2**
- Path of Exile 2, and console realms.
- macOS and Linux clients.
- Exclusive fullscreen mode (it would need injection, which COMPLIANCE.md forbids).
- Reading the user's stash through the OAuth API (stretch only).
- Any automation beyond one game action per user keypress.
- Accounts, a cloud backend, telemetry or analytics.

**Assumptions**
- The game runs in Windowed Fullscreen or Windowed mode.
- The user has an internet connection. Without one, the app falls back to cached data (see NFR-REL-3).

---

## 2. Functional requirements

### 2.1 Connection and lifecycle (CON)
| ID | Pri | Requirement | Acceptance check | Plan |
|---|---|---|---|---|
| CON-1 | M | The client starts the backend on launch and stops it on exit. No backend process is left running. | After closing the client, Task Manager shows no backend process. | B1, F1 |
| CON-2 | M | The client and backend complete the `hello`/`welcome` handshake from PROTOCOL.md, including a `protocol_version` check. | With mismatched versions, the client shows a clear "version mismatch" message instead of failing silently. | B1, F1 |
| CON-3 | M | The backend pushes `health` every 5 s *(target)*. It covers each external source's status, cache age and rate-limit state. | The health panel updates without any user action. | B2 |
| CON-4 | M | If the backend crashes or restarts, the client shows "disconnected" and reconnects on its own. | Kill the backend process: the client shows disconnected and is reconnected within 5 s of the restart. | F1 |

### 2.2 Command center dashboard (DASH)
| ID | Pri | Requirement | Acceptance check | Plan |
|---|---|---|---|---|
| DASH-1 | M | Show a table of currency rates in chaos and divine, with the time of the last update. | The table matches poe.ninja to within one refresh cycle. | I1, F2 |
| DASH-2 | M | A league selector lists current PC leagues. The selection is saved and restored on the next launch. | Choose a league, restart the app, and the same league is selected. Changing the league reloads the rates. | I2, F2 |
| DASH-3 | M | A backend health panel shows each source as OK, degraded or down, with cache ages. | Unplug the network: the sources turn degraded or down within one health cycle. | B2, F2 |
| DASH-4 | S | Show a history of recent price checks: item, estimate and time. | After 3 price checks, all 3 appear, newest first. | F5 |

### 2.3 Item price check (PC)
| ID | Pri | Requirement | Acceptance check | Plan |
|---|---|---|---|---|
| PC-1 | M | A global hotkey sends exactly **one** Ctrl+C to the game, then reads the clipboard. The key must not clash with the game's default bindings. It is set in a config file (a settings screen is stretch). | QA confirms one keypress produces one Ctrl+C (COMPLIANCE.md). The hotkey works while the game has focus. | F4 |
| PC-2 | M | The parser extracts item class, rarity, name, base type, item level, sockets/links, corruption, influences, and implicit, explicit, crafted and fractured mods. | 100% of the fixtures in `shared/samples/` parse to the expected result. Unsupported item kinds return "unsupported" and never crash. | B3 |
| PC-3 | M | Currency, fragments, divination cards, uniques and gems are priced from poe.ninja. | For each of those kinds, the estimate matches the poe.ninja value for that league. | B4 |
| PC-4 | S | Rares are priced with an official trade API search built from their parsed mods. *(Scope set by OPEN_QUESTIONS #7.)* | A rare sample returns low/median/high and a listing count, or "no matches". | B4, I3 |
| PC-5 | M | The overlay result panel shows: item name, estimate (chaos and divine), source, confidence and listing count. Clicking outside it or pressing Esc closes it. | The panel appears near the cursor and does not cover the hovered item. Esc closes it. | F5 |
| PC-6 | M | When a trade search is waiting on a rate limit, the overlay shows a "queued / cooling down" state instead of an error. | Press the hotkey 10 times in 5 s on rares: requests queue, `price.pending` is shown, and no request fails. | B4, F5 |
| PC-7 | M | Text that isn't a PoE item (random clipboard contents) gets a short "not an item" message. | Copy ordinary text and press the hotkey: the overlay says so, and nothing crashes. | B3, F5 |

### 2.4 Stash trade overlay (TR)
| ID | Pri | Requirement | Acceptance check | Plan |
|---|---|---|---|---|
| TR-1 | M | Auto-detect `Client.txt` in the default Steam and standalone install paths, with a manual override in the config file. | Detection works on both install types, and the override takes priority. | B5 |
| TR-2 | M | Tail `Client.txt` and parse incoming trade whispers: buyer, item, price, league, stash tab name and left/top position. The parser must handle the standard whisper formats. | All whisper fixtures parse correctly. New whispers appear within 1 s *(target)* of being written to the log. | B5 |
| TR-3 | M | The overlay lists incoming trade requests. Each can be dismissed. | Three whispers give three entries. Dismissing one removes only that one. | F6 |
| TR-4 | M | Selecting a request highlights the item's cell in the open stash tab. | The highlight lands on the correct cell for a normal tab and a quad tab, at 1920×1080 and 2560×1440. | F6 |
| TR-5 | S | Quick-reply buttons (invite, "one moment", "sold", thanks). Each **user click sends exactly one** chat message. | QA confirms one message per click, with no follow-up actions sent automatically (COMPLIANCE.md). | F6 |
| TR-6 | M | Outgoing whispers and messages from the user themselves are ignored. | The user's own whisper does not create a trade request. | B5 |

### 2.5 Session summary (SES)
| ID | Pri | Requirement | Acceptance check | Plan |
|---|---|---|---|---|
| SES-1 | S | Track the current zone and the time spent in it, from zone-change lines in `Client.txt`. | Zone and timer update within 2 s of entering a zone. | B7 |
| SES-2 | S | Count maps run today and their average duration. Leaving to the hideout and coming back to the same map counts as one map. | The counts match a manual count over a 30-minute session. | B7, F8 |
| SES-3 | C | Estimate currency earned per hour (needs stash access). | n/a for v0.2. | Stretch |

### 2.6 Install and distribution (INS)
| ID | Pri | Requirement | Acceptance check | Plan |
|---|---|---|---|---|
| INS-1 | M | `Quicksilver-Setup.exe` is a standard setup wizard with the pages listed in PLAN.md F7. That includes the "not affiliated with GGG" notice. | Walk through every page on a clean VM. | F7 |
| INS-2 | M | The app runs without the user installing Elixir, Erlang or Qt. | Clean Windows VM: install, launch, and the dashboard shows rates. | B6, F7 |
| INS-3 | M | Uninstalling through Apps & features removes the program. The user's settings stay unless they choose to remove them. | After uninstall, no program files remain, and the settings folder is kept unless removal was chosen. | F7 |
| INS-4 | M | The installer is published as v0.1 on GitHub Releases, with install notes, including the SmartScreen warning. | The release page has the installer and the notes. | F7 |

---

## 3. Non-functional requirements (NFR)

### Performance
| ID | Pri | Requirement | Check |
|---|---|---|---|
| NFR-PERF-1 | M | Price check from hotkey press to overlay result: **≤ 2 s** for poe.ninja-priced items. | Time 20 checks; 95% of them meet the target. |
| NFR-PERF-2 | S | Price check for rares: **≤ 5 s** when no rate limit is active. | Time 10 checks. |
| NFR-PERF-3 | M | Running Quicksilver doesn't noticeably lower game FPS. | In-game FPS with the app running vs. not running, same scene: within ~5%. |
| NFR-PERF-4 | S | At idle, the backend uses < 150 MB RAM and the client < 150 MB *(target)*. | Task Manager after 30 min of idling. |

### Reliability
| ID | Pri | Requirement | Check |
|---|---|---|---|
| NFR-REL-1 | M | A crash in one backend part (for example the log watcher) doesn't take down the others. The supervisor restarts it. | Kill the process during a test; the other features keep working. |
| NFR-REL-2 | M | The app runs for 4 hours of normal play without crashing or growing in memory without limit. | 4-hour soak test before the demo. |
| NFR-REL-3 | M | When a data source is unreachable, the app shows the last cached data, marked stale with its age, instead of empty screens. | Go offline after the first load: the dashboard keeps its data with a "stale" marker. |

### Rate limits and external APIs
| ID | Pri | Requirement | Check |
|---|---|---|---|
| NFR-API-1 | M | Never break a rate-limit rule. Limits are read from response headers, never hardcoded (DATA_SOURCES.md). | No HTTP 429 during the PC-6 hammer test or the 4-hour soak. |
| NFR-API-2 | M | Every external request goes through the backend's clients, with the project User-Agent and contact info. | QA review: no HTTP calls outside the integrations modules. The frontend makes no external calls. |
| NFR-API-3 | M | Each data source's cache follows its documented refresh time. For poe.ninja, honor its `Cache-Control` header. | Logs show no refetch before the cache expires. |

### Compliance and security
| ID | Pri | Requirement | Check |
|---|---|---|---|
| NFR-CMP-1 | M | Every rule in COMPLIANCE.md is followed. Any violation blocks release. | QA compliance review of each feature that sends input or reads game data. |
| NFR-CMP-2 | M | No code, UI layout, icons or wording copied from PoE Overlay. | QA side-by-side review before release. |
| NFR-SEC-1 | M | The backend accepts connections only on `127.0.0.1`. | Connecting from another machine on the network fails. |
| NFR-SEC-2 | S | The client must present a random token, created at each launch, in `hello` (ADR-002). | A WebSocket connection without the token is refused. |
| NFR-PRV-1 | M | No telemetry. Nothing leaves the PC except requests to the documented data sources. | QA review, and a network capture during the soak test. |

### Usability
| ID | Pri | Requirement | Check |
|---|---|---|---|
| NFR-UX-1 | M | The overlay never takes keyboard focus away from the game. Clicks pass through to the game everywhere except on overlay panels. | Play with the overlay open: movement keys and clicks always reach the game. |
| NFR-UX-2 | M | The overlay follows the game window if it moves or changes size. | Resize or move a windowed game: panels stay aligned. |
| NFR-UX-3 | S | Errors are shown in plain language with a next step (e.g. "poe.ninja unreachable, showing data from 12 min ago"). | Review every error message the user can see. |

### Maintainability
| ID | Pri | Requirement | Check |
|---|---|---|---|
| NFR-MNT-1 | M | Backend tests run offline, using recorded API responses and the fixtures in `shared/samples/`. | `mix test` passes with the network disabled. |
| NFR-MNT-2 | M | Both sides match PROTOCOL.md exactly. Any protocol change bumps `protocol_version`. | QA protocol conformance check (qa agent, check 1). |

---

## 4. Open items
- Confirm the *(target)* numbers once B1/F1 run (Week 2).
- PC-4's scope depends on OPEN_QUESTIONS #7 (rares in v0.1 or not).
- The hotkey choice for PC-1 depends on OPEN_QUESTIONS #6.
- TR-4: decide which screen resolutions and UI scale settings the demo must support.
