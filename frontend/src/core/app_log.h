#pragma once
// Where logs go: %LOCALAPPDATA%\Quicksilver\logs\
//   client.log   this app's qDebug/qInfo/qWarning output
//   backend.log  the backend's stderr (its logs), plus launch markers
// Each file is rotated to *.prev.log when the app starts, so the last two runs
// are kept.

#include <QString>

namespace qs::applog {

QString logDir();
QString clientLogPath();
QString backendLogPath();

// Rotates client.log and installs a message handler that writes every message
// to client.log (with a timestamp) and to stderr. Call once, after
// QCoreApplication exists.
void installClientLog();

// Rotates backend.log. BackendProcess appends to it.
void rotateBackendLog();

} // namespace qs::applog
