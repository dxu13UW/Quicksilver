# ADR-001: Qt 6 for the C++ frontend
**Status:** Accepted (Week 1)

**Context**
The client needs two kinds of UI:
- a rich dashboard window (top MVP priority)
- a transparent, always-on-top, click-through overlay

It also needs global hotkeys, clipboard access, and a WebSocket client, all on Windows.

**Options**
- **Qt 6:** widgets and QML, charts, WebSockets, and JSON built in. Translucent, frameless, input-transparent windows are supported. Heavier install. LGPL (fine with dynamic linking).
- **Dear ImGui:** excellent for overlays, but the dashboard, networking, and windowing all have to be assembled by hand.
- **Raw Win32/DirectX:** maximum control, slowest to build.

**Decision**
Qt 6 with CMake, using **Qt Widgets** (not QML). Decided 2026-11-15.
- Plain C++ only, with no second language (QML/JS) to learn under deadline.
- `QTableView` fits the dashboard's tables directly.
- Frameless, translucent, always-on-top widgets are well documented for the overlay.

**Consequences**
- The installer must bundle the Qt runtime (windeployqt).
- Global hotkeys need a small Windows-specific piece, since Qt has no cross-platform global hotkey API.

**Development environment (decided 2026-11-19; replaces the same-day WSL setup)**
Everything is developed **natively on Windows**, in `C:\dev\Quicksilver`.
- **Toolchain:**
  - Git for Windows
  - Erlang/OTP 27 + Elixir 1.18
  - VS 2022 Build Tools ("Desktop development with C++")
  - Qt 6.8 LTS (MSVC 2022 64-bit, plus the **Qt WebSockets** module)
  - CMake
  - Claude Code for Windows. Its shell tool is Git Bash.
- **Why native:** everything Quicksilver touches at runtime is on Windows: the game, Client.txt, the overlay, hotkeys, Job Objects, the installer and the backend release (B6). Developing natively makes every day's test a real end-to-end run, and Windows-only problems show up early instead of in Week 4.
- **Frontend builds:** run CMake with MSVC from a shell that has called `vcvars64.bat`. From Git Bash or scripts, use `cmd /d /c "…vcvars64.bat && cmake …"` (`/d` skips cmd's AutoRun banner).
- **Line endings:** `.gitattributes` keeps LF in every checkout. `.bat`/`.cmd`/`.ps1` files use CRLF.
- **Rejected:**
  - **WSL repo + Windows-side build copy** (the first plan, 2026-11-19): two environments, a copy step, and backend startup only tested on Windows in Week 4.
  - **Repo on `C:\` used from WSL via `/mnt/c`:** slow, and WSL and Windows `mix` would clash over `_build`.
  - **Linux Qt in WSL:** the overlay, global hotkeys and Job Objects are Windows-only.
