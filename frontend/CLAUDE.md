# frontend/ — C++ / Qt 6 client
Owned by the **frontend** agent. See the root CLAUDE.md, docs/ARCHITECTURE.md, docs/PROTOCOL.md and ADR-001.

## Build and test (Week 2, F1 + F2)
- Toolchain: Qt 6.8.3 MSVC 2022 64-bit (`C:\Qt\6.8.3\msvc2022_64`, with Qt WebSockets), VS 2022 Build Tools, CMake + Ninja from vcvars.
- One command, from Git Bash: `cmd //d //c "C:\\dev\\Quicksilver\\frontend\\build.bat"` (Debug build + all tests). Arguments: `clean` (delete the build folder first), `notest`. `QT_DIR` overrides the Qt path; `QS_BUILD_DIR` overrides the build folder (use it while a `Quicksilver.exe` started from `build/` is running, because that locks the exe and DLLs). vcvars prints one harmless "vswhere.exe is not recognized" line.
- Output: `build/Quicksilver.exe`. A post-build `windeployqt` copies the Qt DLLs next to it, so it runs by double-click (turn off with `-DQS_DEPLOY_QT=OFF`).
- Tests: Qt Test, one exe per file in `tests/`, run by `ctest --test-dir build` (build.bat does this). Test exes are built into `build/tests/`, **not** next to `Quicksilver.exe`: windeployqt's Qt DLLs there would make a test look for plugins (e.g. `offscreen`) in `build/` only, and a Debug `qFatal` then hangs on an abort dialog. Widget tests link `quicksilver_ui` (`qs_add_test(... LIBS quicksilver_ui)`) and run with `QT_QPA_PLATFORM=offscreen`. `tests/fake_backend.h` is a scriptable fake gateway that leaves requests unanswered until the test replies (handy for out-of-order cases). `tst_backend_e2e` (label `integration`) boots the real backend offline, about 8 s; skip it with `ctest -LE integration`. Running a test exe by hand needs `C:\Qt\6.8.3\msvc2022_64\bin` on PATH. In Git Bash, Qt Test's console output can be lost, so use `-o out.txt,txt`.

## Running against the backend
- Dev (default): the app runs `mix run --no-halt` in `backend/` by starting **erl.exe directly** (the args elixir.bat would build; see `BackendLocator`). Never through a `.bat`/cmd. It needs `erl` and `elixir` on PATH, or these overrides:
  - `QUICKSILVER_BACKEND_DIR` sets the backend folder (otherwise it's found upward from the exe, then via the source tree).
  - `QUICKSILVER_ERL` sets erl.exe.
  - `QUICKSILVER_ELIXIR_ROOT` sets Elixir's `lib` folder.
- Release (B6/F7): set `QUICKSILVER_BACKEND_EXE` (plus optional `QUICKSILVER_BACKEND_ARGS` and `QUICKSILVER_BACKEND_DIR`). Batch files are refused.
- `QUICKSILVER_READY_TIMEOUT_S` overrides the 20 s READY wait, e.g. when a dev boot has to compile a lot.
- Logs are in `%LOCALAPPDATA%\Quicksilver\logs\`: `client.log` (status transitions, protocol events) and `backend.log` (the backend's stderr and stdout noise). The previous run is kept as `*.prev.log`. `QUICKSILVER_LOG_DIR` moves them (dev; e.g. a second instance that mustn't rotate the first one's logs).
- `QUICKSILVER_SNAPSHOT_DIR` (dev): the window saves `dashboard-NN.png` there after each dashboard change.
- A second instance has its own backend, but both share the backend's `%APPDATA%\Quicksilver\settings.json` (the saved league).

## Layout
- `src/core/`: no widgets. These are what F2+ build on.
  - `protocol_codec`: pure functions (READY line, envelope, token, hello).
  - `ProtocolClient`: one WebSocket, request/reply by id, push signals.
  - `BackendProcess`: launch, READY, stdout/stderr draining, stop.
  - `BackendConnection`: owns both and the retry policy; this is the UI's status source.
  - `BackendLocator`: picks the backend command.
  - `app_log`: the log files.
  - Dashboard (F2), still no widgets; `quicksilver_core` links QtGui only for colours in item models:
    - `Dashboard`: owns the three below and attaches them to one `ProtocolClient`. A successful league change tells the rates feed which league to expect. `connectionLost()` covers silent closes (Restart).
    - `LeagueController`: `leagues.list` on every welcome, `select()` sends `league.set` (one at a time; not for the current league; not offline), revert on error, ignores outdated `current` in out-of-order `leagues.result`. A `league.changed` push (id null) sets `current()` without sending anything (`backendChanged`); while a user change is pending, the pending choice stays shown and the reply decides.
    - `RatesFeed`: `rates.subscribe` on every welcome; `rates.update` reply/push → Ready; subscribe error or the rates error push (`topic: "rates"`) → Error with the table cleared; keeps last rows while disconnected (`live()` false).
    - `RatesModel` (in-place, id-keyed updates for the same league, so sort and scroll survive) + `RatesSortProxy` (numeric `SortRole`, nulls last both ways, ties keep backend order).
    - `HealthModel`: the `health` push, sources in the given order, `StatusRole` for the badge.
    - `dashboard_format`: number, age and source-name wording (one place, unit-tested).
- `src/platform/`: the only Windows-specific code. `ProcessJob` is a kill-on-close Job Object. `ChildStdin` is an anonymous-pipe stdin, because erl.exe never reads QProcess's named-pipe stdin. Each has a stub for other OSes.
- `src/ui/` (`quicksilver_ui` static lib, so widget tests can link it): `CommandCenterWindow` (connection strip on top; tabs "Dashboard" and "Backend log"), `LeagueSelector` (sends only on the combo's user-only `activated()`, fills under `QSignalBlocker`), `RatesPanel` (heading, meta line with age, STALE / OFFLINE chips, name filter, table or message page), `HealthPanel` + `StatusBadgeDelegate`.
