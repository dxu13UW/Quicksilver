# Architecture

```
┌──────────────── Windows PC ─────────────────────────────────────┐
│                                                                 │
│  Path of Exile (Windowed Fullscreen)                            │
│     │ writes                    ▲ Ctrl+C (one action per key)   │
│     ▼                           │                               │
│  Client.txt log         ┌───────┴─────────── C++ / Qt 6 ──────┐  │
│     │                   │ Hotkey + clipboard reader           │  │
│     │ tail              │ Command center window (dashboard)   │  │
│     ▼                   │ Overlay window (transparent, top)   │  │
│  ┌──── Elixir/OTP ────┐ └───────▲────────────────────────────┘  │
│  │ Gateway (WS)  ◄────┼─── WebSocket on 127.0.0.1 ──┘             │
│  │ Item parser        │                                         │
│  │ Pricing            │                                         │
│  │ Log watcher        │                                         │
│  │ Session tracker    │                                         │
│  │ API clients + rate │──── HTTPS ───► pathofexile.com, poe.ninja │
│  │ limiter + cache    │                                         │
│  └────────────────────┘                                         │
└─────────────────────────────────────────────────────────────────┘
```

## Why this split
- **Elixir backend.** It fits the backend's jobs:
  - lots of concurrent, independent, long-running jobs (cache refreshers, a log tailer, per-endpoint rate limiters)
  - supervisors that restart them when they crash
  - pattern matching suited to parsing item text and log lines
- **C++/Qt frontend.** It fits the frontend's jobs:
  - native Windows windows, including a transparent click-through overlay
  - global hotkeys and clipboard access
  - a rich dashboard
- **One local WebSocket.** It is one connection, it's bidirectional (the backend can push trade whispers and price updates), and it's easy to inspect while debugging.

## Planned backend components (OTP processes)
| Component | Responsibility |
|---|---|
| Gateway | WebSocket server, routes messages to/from the client |
| ItemParser | Pure module: clipboard text → structured item |
| Pricer | Chooses a pricing strategy per item type, returns an estimate + confidence |
| Ninja client | Fetches and caches poe.ninja overviews on a schedule |
| Trade client | Official trade search/fetch with dynamic rate limiting |
| RateLimiter | One per external policy; reads rate-limit headers and queues requests |
| LogWatcher | Tails Client.txt, emits events (whisper, zone change, etc.) |
| TradeWatch | Turns whisper events into trade requests for the overlay |
| Session | Tracks zones/maps/time from log events |

Single Mix app with Bandit + WebSock, no Phoenix (see ADR-002).

## Planned frontend components
| Component | Responsibility |
|---|---|
| BackendConnection | WebSocket client, reconnects, message dispatch |
| HotkeyService | Global hotkeys; triggers clipboard copy |
| CommandCenterWindow | Dashboard tabs: rates, price history, trades, session, health |
| OverlayWindow | Frameless, translucent, always-on-top; positioned over game window |
| Panels | Price result, trade request list, stash highlight |

## Important constraints
- **Game display mode.** The overlay only works when PoE is in **Windowed Fullscreen** or **Windowed** mode. Exclusive fullscreen would require injecting into the game, which is forbidden (COMPLIANCE.md).
- **Backend lifetime.** The backend starts with the client and stops with it. The client launches the backend binary.
