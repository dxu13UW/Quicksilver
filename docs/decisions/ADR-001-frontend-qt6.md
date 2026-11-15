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
