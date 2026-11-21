#include "platform/child_stdin.h"

#include <QProcess>

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

namespace qs::platform {

struct ChildStdin::Impl {
    HANDLE read = nullptr;  // child's end (inheritable)
    HANDLE write = nullptr; // ours (never inheritable)
    bool usingQtPipe = false;

    void closeRead()
    {
        if (read) {
            CloseHandle(read);
            read = nullptr;
        }
    }
    void closeWrite()
    {
        if (write) {
            CloseHandle(write);
            write = nullptr;
        }
    }
};

ChildStdin::ChildStdin() : d(std::make_unique<Impl>()) {}

ChildStdin::~ChildStdin()
{
    d->closeRead();
    d->closeWrite();
}

bool ChildStdin::prepare(QProcess &process)
{
    d->closeRead();
    d->closeWrite();
    // Both ends non-inheritable first, then only the read end inheritable, so
    // the write end can never leak into any child.
    if (!CreatePipe(&d->read, &d->write, nullptr, 0)
        || !SetHandleInformation(d->read, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT)) {
        d->closeRead();
        d->closeWrite();
        d->usingQtPipe = true; // fall back to QProcess's pipe
        return false;
    }
    d->usingQtPipe = false;
    process.setStandardInputFile(QProcess::nullDevice());
    HANDLE read = d->read;
    auto previous = process.createProcessArgumentsModifier();
    process.setCreateProcessArgumentsModifier([previous, read](QProcess::CreateProcessArguments *args) {
        if (previous)
            previous(args);
        args->startupInfo->hStdInput = read; // QProcess already set STARTF_USESTDHANDLES
    });
    return true;
}

void ChildStdin::afterStart()
{
    d->closeRead();
}

void ChildStdin::close(QProcess &process)
{
    if (d->usingQtPipe)
        process.closeWriteChannel();
    d->closeRead();
    d->closeWrite();
}

} // namespace qs::platform
