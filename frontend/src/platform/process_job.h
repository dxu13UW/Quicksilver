#pragma once
// Platform layer: tie a child process's lifetime to ours (PROTOCOL "Cleanup",
// REQUIREMENTS CON-1).
//
// Windows: a Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. The handle is
// not inheritable, so only this process holds it; when we exit or crash, the
// OS closes it and ends every process in the job. To leave no window in which
// the child could start grandchildren outside the job, prepare() makes
// QProcess create the child suspended; adopt() assigns it to the job and only
// then resumes it.
//
// Elsewhere: a no-op stub (the app is Windows-only; this keeps the core
// library portable for tooling).

#include <QString>

#include <memory>

class QProcess;

namespace qs::platform {

class ProcessJob {
public:
    ProcessJob();
    ~ProcessJob(); // closes the job handle, which ends every process in it
    ProcessJob(const ProcessJob &) = delete;
    ProcessJob &operator=(const ProcessJob &) = delete;

    // False if the job could not be created; error() says why.
    bool isValid() const;
    QString error() const;

    // Call before QProcess::start().
    void prepare(QProcess &process);
    // Call once the process has started (QProcess::started). Assigns it to the
    // job and resumes it. Always resumes, even if assignment fails (then
    // returns false and error() says why).
    bool adopt(qint64 pid);
    // Ends every process in the job now.
    void terminate(unsigned exitCode = 1);

private:
    struct Impl;
    std::unique_ptr<Impl> d;
};

} // namespace qs::platform
