#pragma once
// Decides which program starts the backend. Two modes:
//
// 1. Explicit (later: the release executable, B6/F7):
//      QUICKSILVER_BACKEND_EXE   program to run (must not be a .bat/.cmd)
//      QUICKSILVER_BACKEND_ARGS  optional arguments, split like a command line
//      QUICKSILVER_BACKEND_DIR   optional working directory (default: the exe's dir)
//
// 2. Development (default): `mix run --no-halt` in backend/, started as
//    erl.exe directly with the arguments elixir.bat would build (the same way
//    backend/test/e2e/launch_e2e_test.exs does it). cmd.exe is never in
//    between: its AutoRun hook and batch-file stdio handling break the pipes.
//      QUICKSILVER_BACKEND_DIR   backend/ (default: searched upward from the
//                                exe's dir, then the source tree)
//      QUICKSILVER_ERL           erl.exe (default: from PATH)
//      QUICKSILVER_ELIXIR_ROOT   Elixir's lib/ dir (default: <elixir on PATH>/../lib)

#include <QProcessEnvironment>
#include <QString>
#include <QStringList>

namespace qs {

struct BackendCommand {
    QString program;
    QStringList arguments;
    QString workingDirectory;
    QString mode;  // "explicit" or "dev"
    QString error; // non-empty: the command could not be resolved
    bool ok() const { return error.isEmpty(); }
    QString display() const; // for logs and the UI
};

class BackendLocator {
public:
    // `appDir` is where Quicksilver.exe lives; `sourceDir` is the frontend
    // source dir baked in at build time (dev fallback). Both may be empty.
    static BackendCommand resolve(const QProcessEnvironment &env, const QString &appDir,
                                  const QString &sourceDir);

    // The erl.exe arguments that run `mix <mixArgs>` with Elixir at `elixirLib`.
    static QStringList devErlArguments(const QString &elixirLib, const QStringList &mixArgs);

    // True for programs that would run through cmd.exe (.bat / .cmd).
    static bool isBatchFile(const QString &program);
};

} // namespace qs
