#include "platform/child_stdin.h"

#include <QProcess>

// Non-Windows: QProcess's own stdin pipe works; nothing to swap.

namespace qs::platform {

struct ChildStdin::Impl {};

ChildStdin::ChildStdin() : d(std::make_unique<Impl>()) {}
ChildStdin::~ChildStdin() = default;
bool ChildStdin::prepare(QProcess &) { return true; }
void ChildStdin::afterStart() {}
void ChildStdin::close(QProcess &process) { process.closeWriteChannel(); }

} // namespace qs::platform
