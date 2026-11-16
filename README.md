# Quicksilver

*Named after the speed utility flask, and a nod to the Elixir backend.*

A companion app for Path of Exile 1: a standalone **command center** window plus an **in-game overlay**, backed by a local **Elixir** service that talks to the official trade API, poe.ninja, and other data sources.

Built solo for Artifact 5 (The Moonshot), with Claude Code subagents acting as the team.

## Planned features (MVP priority order)
1. **Command center dashboard**: currency rates, league info, recent price checks, backend health.
2. **Item price check**: hotkey on a hovered item → overlay shows estimated value.
3. **Stash trade overlay**: incoming trade whispers → highlights the item's stash cell and offers quick replies.
4. **Session summary**: maps run, time spent, and (stretch) currency earned.

## Repository map
| Path | What lives there |
|---|---|
| `CLAUDE.md` | What every agent must know before touching anything |
| `docs/PLAN.md` | Milestones and work items, week by week |
| `docs/REQUIREMENTS.md` | What "done" means: numbered requirements with acceptance checks |
| `docs/ARCHITECTURE.md` | How the pieces fit together |
| `docs/PROTOCOL.md` | The contract between the C++ client and the Elixir service |
| `docs/DATA_SOURCES.md` | External APIs, rate limits, and caching rules |
| `docs/COMPLIANCE.md` | GGG tool rules and copyright boundaries |
| `docs/decisions/` | Architecture decision records (ADRs) |
| `LOG.md` | Running log of plans, sessions, and changes |
| `OPEN_QUESTIONS.md` | Things still undecided |
| `.claude/agents/` | Subagent definitions (backend, frontend, integrations, QA, scribe) |
| `backend/` | Elixir service (empty until Week 2) |
| `frontend/` | C++ / Qt 6 client (empty until Week 2) |
| `shared/` | Protocol schemas and sample item texts used by both sides |

## Notices
- This product isn't affiliated with or endorsed by Grinding Gear Games in any way.
- Quicksilver reads the game's `Client.txt` log file to detect trade whispers and zone changes. It reads the clipboard only when you press the price-check hotkey. It never reads game memory or modifies game files.
