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
- Handoffs: integrations, to record the verified endpoints and rate-limit headers in DATA_SOURCES.md.
- Next step:
  - Review the *(target)* numbers in REQUIREMENTS.md.
  - Collect item samples.
  - Install Qt and MSVC.
