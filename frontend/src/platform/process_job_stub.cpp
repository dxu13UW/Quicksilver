#include "platform/process_job.h"

// Non-Windows stub: no job object; the backend's stdin guard is the cleanup.

namespace qs::platform {

struct ProcessJob::Impl {};

ProcessJob::ProcessJob() : d(std::make_unique<Impl>()) {}
ProcessJob::~ProcessJob() = default;
bool ProcessJob::isValid() const { return false; }
QString ProcessJob::error() const { return QStringLiteral("process jobs are Windows-only"); }
void ProcessJob::prepare(QProcess &) {}
bool ProcessJob::adopt(qint64) { return false; }
void ProcessJob::terminate(unsigned) {}

} // namespace qs::platform
