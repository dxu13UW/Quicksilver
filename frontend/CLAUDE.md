# frontend/ — C++ / Qt 6 client
Owned by the **frontend** agent. See the root CLAUDE.md, docs/ARCHITECTURE.md, docs/PROTOCOL.md and ADR-001.

## Build and test (Week 2, F1)
- Toolchain: Qt 6.8.3 MSVC 2022 64-bit (`C:\Qt\6.8.3\msvc2022_64`, with Qt WebSockets), VS 2022 Build Tools, CMake + Ninja from vcvars.
- One command, from Git Bash: `cmd //d //c "C:\\dev\\Quicksilver\\frontend\\build.bat"` (Debug build + all tests). Arguments: `clean` (delete `build/` first), `notest`. `QT_DIR` overrides the Qt path. vcvars prints one harmless "vswhere.exe is not recognized" line.
- Output: `build/Quicksilver.exe`. A post-build `windeployqt` copies the Qt DLLs next to it, so it runs by double-click (turn off with `-DQS_DEPLOY_QT=OFF`).
- Tests: Qt Test, one exe per file in `tests/`, run by `ctest --test-dir build` (build.bat does this). `tst_backend_e2e` (label `integration`) boots the real backend offline, about 8 s; skip it with `ctest -LE integration`. Running a test exe by hand needs `C:\Qt\6.8.3\msvc2022_64\bin` on PATH. In Git Bash, Qt Test's console output can be lost, so use `-o out.txt,txt`.

## Running against the backend
- Dev (default): the app runs `mix run --no-halt` in `backend/` by starting **erl.exe directly** (the args elixir.bat would build; see `BackendLocator`). Never through a `.bat`/cmd. It needs `erl` and `elixir` on PATH, or these overrides:
  - `QUICKSILVER_BACKEND_DIR` sets the backend folder (otherwise it's found upward from the exe, then via the source tree).
  - `QUICKSILVER_ERL` sets erl.exe.
  - `QUICKSILVER_ELIXIR_ROOT` sets Elixir's `lib` folder.
- Release (B6/F7): set `QUICKSILVER_BACKEND_EXE` (plus optional `QUICKSILVER_BACKEND_ARGS` and `QUICKSILVER_BACKEND_DIR`). Batch files are refused.
- `QUICKSILVER_READY_TIMEOUT_S` overrides the 20 s READY wait, e.g. when a dev boot has to compile a lot.
- Logs are in `%LOCALAPPDATA%\Quicksilver\logs\`: `client.log` (status transitions, protocol events) and `backend.log` (the backend's stderr and stdout noise). The previous run is kept as `*.prev.log`.

## Layout
- `src/core/`: no widgets. These are what F2+ build on.
  - `protocol_codec`: pure functions (READY line, envelope, token, hello).
  - `ProtocolClient`: one WebSocket, request/reply by id, push signals.
  - `BackendProcess`: launch, READY, stdout/stderr draining, stop.
  - `BackendConnection`: owns both and the retry policy; this is the UI's status source.
  - `BackendLocator`: picks the backend command.
  - `app_log`: the log files.
- `src/platform/`: the only Windows-specific code. `ProcessJob` is a kill-on-close Job Object. `ChildStdin` is an anonymous-pipe stdin, because erl.exe never reads QProcess's named-pipe stdin. Each has a stub for other OSes.
- `src/ui/`: `CommandCenterWindow`.
- F2: use `connection->client()->request(type, payload, handler)` and the `pushReceived` / `healthReceived` signals. Replace the raw health tree in `CommandCenterWindow`.
