#include "platform/process_job.h"

#include <QProcess>

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <tlhelp32.h>

namespace qs::platform {

namespace {
QString lastErrorText(const char *what)
{
    const DWORD err = GetLastError();
    wchar_t *buf = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, err, 0, reinterpret_cast<wchar_t *>(&buf), 0, nullptr);
    QString text = buf ? QString::fromWCharArray(buf).trimmed() : QString();
    if (buf)
        LocalFree(buf);
    return QStringLiteral("%1 failed (%2): %3").arg(QLatin1String(what)).arg(err).arg(text);
}

// Resumes every thread of a process created with CREATE_SUSPENDED (it has
// exactly one). Returns how many threads were resumed.
int resumeProcessThreads(DWORD pid)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE)
        return 0;
    int resumed = 0;
    THREADENTRY32 te{};
    te.dwSize = sizeof(te);
    if (Thread32First(snap, &te)) {
        do {
            if (te.th32OwnerProcessID != pid)
                continue;
            HANDLE th = OpenThread(THREAD_SUSPEND_RESUME, FALSE, te.th32ThreadID);
            if (!th)
                continue;
            if (ResumeThread(th) != static_cast<DWORD>(-1))
                ++resumed;
            CloseHandle(th);
        } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
    return resumed;
}
} // namespace

struct ProcessJob::Impl {
    HANDLE job = nullptr;
    QString error;
};

ProcessJob::ProcessJob() : d(std::make_unique<Impl>())
{
    d->job = CreateJobObjectW(nullptr, nullptr); // not inheritable
    if (!d->job) {
        d->error = lastErrorText("CreateJobObject");
        return;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(d->job, JobObjectExtendedLimitInformation, &info, sizeof(info))) {
        d->error = lastErrorText("SetInformationJobObject");
        CloseHandle(d->job);
        d->job = nullptr;
    }
}

ProcessJob::~ProcessJob()
{
    if (d->job)
        CloseHandle(d->job);
}

bool ProcessJob::isValid() const { return d->job != nullptr; }
QString ProcessJob::error() const { return d->error; }

void ProcessJob::prepare(QProcess &process)
{
    if (!d->job)
        return; // no job: start normally, the stdin guard is the only cleanup
    auto previous = process.createProcessArgumentsModifier(); // e.g. ChildStdin's
    process.setCreateProcessArgumentsModifier([previous](QProcess::CreateProcessArguments *args) {
        if (previous)
            previous(args);
        args->flags |= CREATE_SUSPENDED;
    });
}

bool ProcessJob::adopt(qint64 pid)
{
    const DWORD wpid = static_cast<DWORD>(pid);
    bool ok = false;
    if (d->job) {
        HANDLE proc = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, wpid);
        if (!proc) {
            d->error = lastErrorText("OpenProcess");
        } else {
            ok = AssignProcessToJobObject(d->job, proc) != 0;
            if (!ok)
                d->error = lastErrorText("AssignProcessToJobObject");
            CloseHandle(proc);
        }
    }
    resumeProcessThreads(wpid);
    return ok;
}

void ProcessJob::terminate(unsigned exitCode)
{
    if (d->job)
        TerminateJobObject(d->job, exitCode);
}

} // namespace qs::platform
