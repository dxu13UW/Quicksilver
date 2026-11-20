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

**Build setup (decided 2026-11-19)**
Development happens in WSL (Debian). Qt 6.8 LTS (MSVC 2022 64-bit, plus the Qt WebSockets module) and the VS 2022 Build Tools are installed on Windows.
- **Source of truth:** the repo stays on the WSL disk. All edits and git happen there, and Elixir stays fast.
- **Build from a Windows-side copy:** a build script copies `frontend/` and `shared/` to a Windows folder (e.g. `C:\dev\quicksilver-build\`). It then runs the MSVC/CMake build there through `cmd.exe /d /c` (`/d` skips cmd's AutoRun banner) after `vcvars64.bat`.
  - The reason: MSVC and `cmd.exe` don't work from `\\wsl.localhost\…` paths, and builds across that boundary are slow.
  - **Never edit the Windows copy.** Every build overwrites it.
- **Dev runtime:** the backend runs in WSL on port 47474, and `Quicksilver.exe` runs on Windows. WSL uses `networkingMode=mirrored`, so both sides share `127.0.0.1`.
- **Rejected:**
  - Moving the repo to `C:\` and using it via `/mnt/c`: Elixir and git get several times slower.
  - Linux Qt in WSL: the overlay, global hotkeys and Job Objects are Windows-only.
- **Later (B6):** the installer needs a Windows build of the Elixir release, so Erlang/Elixir get installed on Windows in Week 4.
