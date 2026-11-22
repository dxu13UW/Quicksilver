#include "core/app_log.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QMutex>
#include <QStandardPaths>

#include <cstdio>

namespace qs::applog {

namespace {
QFile *g_clientLog = nullptr;
QMutex g_mutex;

void rotate(const QString &path)
{
    if (!QFile::exists(path))
        return;
    QString prev = path;
    prev.replace(QStringLiteral(".log"), QStringLiteral(".prev.log"));
    QFile::remove(prev);
    QFile::rename(path, prev);
}

void handler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    const char *level = "debug";
    switch (type) {
    case QtDebugMsg: level = "debug"; break;
    case QtInfoMsg: level = "info"; break;
    case QtWarningMsg: level = "warning"; break;
    case QtCriticalMsg: level = "critical"; break;
    case QtFatalMsg: level = "fatal"; break;
    }
    const QString line = QStringLiteral("%1 [%2] %3: %4\n")
                             .arg(QDateTime::currentDateTime().toString(Qt::ISODateWithMs),
                                  QLatin1String(level),
                                  QLatin1String(ctx.category ? ctx.category : "default"), msg);
    const QByteArray bytes = line.toUtf8();
    {
        QMutexLocker lock(&g_mutex);
        if (g_clientLog) {
            g_clientLog->write(bytes);
            g_clientLog->flush();
        }
    }
    std::fputs(bytes.constData(), stderr);
    std::fflush(stderr);
}
} // namespace

QString logDir()
{
    // Dev override, e.g. to run a second instance without touching the
    // first one's logs.
    const QString overrideDir = qEnvironmentVariable("QUICKSILVER_LOG_DIR");
    if (!overrideDir.isEmpty()) {
        QDir().mkpath(overrideDir);
        return QDir(overrideDir).absolutePath();
    }
    QString base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    if (base.isEmpty())
        base = QDir::tempPath();
    const QString dir = base + QStringLiteral("/Quicksilver/logs");
    QDir().mkpath(dir);
    return dir;
}

QString clientLogPath() { return logDir() + QStringLiteral("/client.log"); }
QString backendLogPath() { return logDir() + QStringLiteral("/backend.log"); }

void installClientLog()
{
    const QString path = clientLogPath();
    rotate(path);
    auto *f = new QFile(path);
    if (f->open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        g_clientLog = f; // lives until process exit
    } else {
        delete f;
    }
    qInstallMessageHandler(handler);
}

void rotateBackendLog()
{
    rotate(backendLogPath());
}

} // namespace qs::applog
