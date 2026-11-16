# Portfolio card draft: Artifact 5 (The Moonshot)

**Title:** Quicksilver: a Path of Exile companion
**Link:** https://github.com/dxu13UW/Quicksilver

**Status (Week 1):** Planned and scaffolded Quicksilver, a Path of Exile companion app for Windows. It has three parts:
- an Elixir/OTP backend that handles prices, the trade API and log watching
- a C++/Qt 6 command center window
- a transparent in-game overlay for one-key price checks and trade requests

This week I wrote the plan, architecture, client–backend protocol, and compliance rules (no memory reading, one game action per keypress). I also wrote ADRs for the main tech choices and a requirements doc with testable acceptance criteria. I tested the live APIs and found that poe.ninja had moved its endpoints, so the plan uses the new ones. I set up five Claude Code subagents (backend, frontend, integrations, QA, scribe) as the "team". No app code yet, by design; the first working version starts in Week 2.

---

## Weekly log (for the final reflection)
- **Week 1 (Nov 9–15):** Scaffold, decisions (Qt Widgets; single Elixir app with Bandit + WebSock; public repo), requirements, live API check. Repo published.
