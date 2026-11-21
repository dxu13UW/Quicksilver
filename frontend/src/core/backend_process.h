#pragma once
// Starts and stops the backend process (PROTOCOL "Launch and lifetime").
//
// start():
//   - a fresh 32-hex token, QUICKSILVER_PORT=0, QUICKSILVER_TOKEN=<token>
//   - the child is created suspended, put in a kill-on-close Job Object, then
//     resumed (platform/process_job.h)
//   - stdout is read line by line until the READY line (at most
//     readyTimeoutMs, default 20 s); other stdout lines (dev compile output)
//     go to the log. stderr is drained continuously into backend.log and a
//     ring buffer of recent lines.
//   - stdin stays open for the whole run; the backend exits when it closes
//     (on Windows an anonymous pipe, see platform/child_stdin.h).
// stop(): closes stdin, waits up to 3 s, then ends the job. Blocking.
//
// It never restarts by itself; BackendConnection owns that policy.

#include "core/backend_locator.h"

#include <QFile>
#include <QHash>
#include <QObject>
#include <QProcess>
#include <QStringList>
#include <QTimer>

#include <memory>

namespace qs {
namespace platform {
class ChildStdin;
class ProcessJob;
} // namespace platform

class BackendProcess : public QObject {
    Q_OBJECT
public:
    enum class State { NotRunning, Starting, Ready, Stopping };
    Q_ENUM(State)

    enum class Failure {
        FailedToStart,   // the program couldn't be started (or wasn't resolved)
        ReadyTimeout,    // no READY line in time; the process was stopped
        VersionMismatch, // READY carried another protocol_version; stopped
        Exited,          // the process ended without stop() being called
    };
    Q_ENUM(Failure)

    explicit BackendProcess(QObject *parent = nullptr);
    ~BackendProcess() override; // stop()s a running backend

    void setReadyTimeoutMs(int ms) { m_readyTimeoutMs = ms; }
    // Extra environment variables for the child (e.g. QUICKSILVER_OFFLINE=1 in tests).
    void setExtraEnvironment(const QHash<QString, QString> &env) { m_extraEnv = env; }
    // Where stderr is appended. Empty: no file, ring buffer only.
    void setLogFilePath(const QString &path) { m_logFilePath = path; }

    void start(const BackendCommand &command);
    void stop(int graceMs = 3000);

    State state() const { return m_state; }
    QString token() const { return m_token; }
    quint16 port() const { return m_port; }
    qint64 processId() const;
    bool jobActive() const { return m_jobActive; }
    QStringList recentLog() const { return m_recent; }

signals:
    void ready(quint16 port, const QString &token);
    void failed(qs::BackendProcess::Failure kind, const QString &detail);
    void logLine(const QString &line);

private:
    void onStarted();
    void onStdout();
    void onStderr();
    void onFinished(int exitCode, QProcess::ExitStatus status);
    void onErrorOccurred(QProcess::ProcessError error);
    void onReadyTimeout();
    void handleStdoutLine(const QByteArray &line);
    void appendLog(const QString &line);
    void fail(Failure kind, const QString &detail, bool stopProcess);
    void teardown();

    QProcess *m_process = nullptr;
    std::unique_ptr<platform::ProcessJob> m_job;
    std::unique_ptr<platform::ChildStdin> m_stdin;
    bool m_jobActive = false;
    State m_state = State::NotRunning;
    QString m_token;
    quint16 m_port = 0;
    int m_readyTimeoutMs = 20'000;
    QHash<QString, QString> m_extraEnv;
    QString m_logFilePath;
    QFile m_logFile;
    QByteArray m_stdoutBuf;
    QByteArray m_stderrBuf;
    QStringList m_recent;
    QTimer m_readyTimer;
};

} // namespace qs
