#pragma once
// Platform layer: the backend's stdin pipe, which we keep open for the whole
// run and close to ask the backend to exit (PROTOCOL "Cleanup").
//
// Why not QProcess's own stdin on Windows: QProcess hands the child a named
// pipe, and erl.exe (-noshell) never reads from it: no data, no EOF (checked
// 2026-11-19 with OTP 27; sort.exe reads it fine, and erl reads an anonymous
// pipe fine, which is what Erlang ports and cmd use). So on Windows we give
// the child the read end of an anonymous pipe (CreatePipe) by swapping
// STARTUPINFO.hStdInput in QProcess's CreateProcess modifier. QProcess itself
// gets the null device as stdin. Our write end is never inheritable, so
// closing it is EOF for the child.
//
// Elsewhere: QProcess's own stdin (closeWriteChannel).

#include <memory>

class QProcess;

namespace qs::platform {

class ChildStdin {
public:
    ChildStdin();
    ~ChildStdin(); // closes both ends
    ChildStdin(const ChildStdin &) = delete;
    ChildStdin &operator=(const ChildStdin &) = delete;

    // Call before QProcess::start(), and before ProcessJob::prepare() or
    // after: both chain the CreateProcess modifier.
    bool prepare(QProcess &process);
    // Call once the process has started: drops our copy of the child's end.
    void afterStart();
    // EOF for the child.
    void close(QProcess &process);

private:
    struct Impl;
    std::unique_ptr<Impl> d;
};

} // namespace qs::platform
