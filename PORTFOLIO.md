# Portfolio card draft: Artifact 5 (The Moonshot)

**Title:** Quicksilver: a Path of Exile companion
**Link:** https://github.com/dxu13UW/Quicksilver

**Status (Week 2):** Quicksilver now has a working walking skeleton. Both halves run, talk to each other over the local protocol, and the command center shows live data.
- **Backend (Elixir):**
  - a WebSocket gateway on 127.0.0.1 with a version handshake and a per-launch token. It also refuses connections that carry a browser `Origin` header.
  - health pushes every 5 s.
  - poe.ninja and official league-list clients, with caching and a rate limiter driven by the servers' rate-limit headers.
  - dashboard routes: league list, league selection, currency rates.
- **Frontend (C++/Qt 6):** `Quicksilver.exe` starts the backend and supervises it (reconnects or restarts it on failure). It shows the connection status and a dashboard with a league selector, a currency rates table and a backend health panel. In a live run it listed 8 PC leagues and 108 currency rates, and one league switch loaded the new league's rates.

How I built it: I'm the only developer, and I direct Claude Code subagents that each own one area (backend, integrations, frontend, QA, scribe). `docs/PROTOCOL.md` is the contract between the two halves. When an agent found the protocol silent or unclear, it asked; I decided, and the doc changed before the code did. Each session and decision is logged.

Evidence:
- Backend: 174 ExUnit tests, 0 failures, including an end-to-end boot test (run 3 times).
- Frontend: 9 Qt Test programs with 162 cases, all passing from a clean build, including end-to-end tests against the real backend.
- QA review: 6 of 6 areas PASS (protocol, compliance, external calls, tests, requirements, docs), no blockers.
- Test plan: 150 cases, each traced to requirement IDs. At the review, 120 were covered, 11 partial, 6 gaps, 4 waiting on the dashboard, and 9 N/A or review-only. Some of those gaps were closed with new tests afterwards; the plan's table hasn't been re-counted yet.

Notable problems solved:
- A cmd.exe startup script on my machine printed a banner and changed directory in every shell, which broke the MSVC build setup. I made it skip non-interactive shells.
- On Windows, the Erlang backend never saw its input close when Qt started it (Qt uses a named pipe), so quitting took 3 s and ended in a forced kill. Giving the backend an anonymous pipe made shutdown clean, in about 1 s.
- The backend runs inside a Windows Job Object, so it can't outlive the app even when the app is force-killed (checked with `taskkill /F`).
- poe.ninja sits behind a CDN that can serve copies that are already old. Cache freshness subtracts the CDN's `Age` header, so we don't refetch the same stale copy.
- Agents' protocol questions were settled in PROTOCOL.md before coding. One result is a new `league.changed` push, so the app learns when the backend switches leagues on its own.

Known gaps: a few client tests (retry policy, startup timeout) and a manual network-loss check are still open.

Next week (Week 3, Nov 23–29, a light Thanksgiving week):
- the item text parser, tested against sample items (I still need to collect these);
- pricing: poe.ninja first, and the trade API on demand for rares, behind a kill switch;
- a trade API client that obeys rate-limit headers;
- the transparent overlay window and hotkey;
- the price result panel.

**Status (Week 1):** Planned and scaffolded Quicksilver, a Path of Exile companion app for Windows. It has three parts:
- an Elixir/OTP backend that handles prices, the trade API and log watching
- a C++/Qt 6 command center window
- a transparent in-game overlay for one-key price checks and trade requests

This week I wrote the plan, architecture, client–backend protocol, and compliance rules (no memory reading, one game action per keypress). I also wrote ADRs for the main tech choices and a requirements doc with testable acceptance criteria. I tested the live APIs and found that poe.ninja had moved its endpoints, so the plan uses the new ones. I set up five Claude Code subagents (backend, frontend, integrations, QA, scribe) as the "team". No app code yet, by design; the first working version starts in Week 2.

---

## Weekly log (for the final reflection)
- **Week 1 (Nov 9–15):** Scaffold, decisions (Qt Widgets; single Elixir app with Bandit + WebSock; public repo), requirements, live API check. Repo published.
- **Week 2 (Nov 16–22):** Walking skeleton. Backend gateway, poe.ninja and league clients, rate limiter. Qt command center with dashboard. Test plan and QA review (6/6 PASS). Moved development from WSL to native Windows. Protocol decisions: Origin check, `welcome.league` is the active league, rates error push, `league.changed` push, cold-start `rates.subscribe` waits for the league.
