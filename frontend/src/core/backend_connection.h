#pragma once
// Owns the backend process and the protocol connection, and decides what to do
// when either goes away. The UI only reads status() / statusChanged() and uses
// client() for requests and pushes (F2 builds on that).
//
// Policy (REQUIREMENTS CON-1, CON-2, CON-4; PROTOCOL "Launch and lifetime"):
// - Launch -> READY (20 s max) -> connect + hello -> welcome = Connected.
// - The socket drops while the backend still runs: reconnect after
//   0.5, 1, 2, 4, 5, 5 ... s. After 5 failed tries in a row, restart the backend.
// - The backend exits on its own (crash, killed): show Disconnected and
//   restart it after 1, 2, 4, 8, 15 s. After 5 restarts in a row that never
//   reach Connected, stop and show Failed with a Restart action.
// - No automatic retry for things a retry can't fix: no READY within 20 s,
//   the program can't be started, protocol mismatch, unauthorized or another
//   handshake rejection. These show Failed; the user can press Restart.
// - Any success (welcome) resets both retry counters.

#include "core/backend_locator.h"
#include "core/backend_process.h"
#include "core/protocol_client.h"

#include <QObject>
#include <QTimer>

namespace qs {

class BackendConnection : public QObject {
    Q_OBJECT
public:
    enum class Phase {
        Idle,            // not started, or shut down
        StartingBackend, // process launched, waiting for READY
        Connecting,      // READY seen; WebSocket + hello in progress
        Connected,       // welcome received
        Disconnected,    // lost; an automatic retry is scheduled
        Failed,          // stopped; needs the user (Restart)
    };
    Q_ENUM(Phase)

    struct Status {
        Phase phase = Phase::Idle;
        QString headline;
        QString detail;
        QString serverVersion; // set while Connected
        QString errorCode;     // protocol error code for handshake failures
    };

    BackendConnection(BackendCommand command, QObject *parent = nullptr);
    ~BackendConnection() override;

    ProtocolClient *client() { return &m_client; }
    BackendProcess *process() { return &m_process; }
    const Status &status() const { return m_status; }

    void start();
    void restart();  // user action: resets the retry counters
    void shutdown(); // stops the backend (stdin close, 3 s grace); no more retries

    // Tests can shorten the waits.
    void setRetryScale(double scale) { m_retryScale = scale; }

signals:
    void statusChanged(const qs::BackendConnection::Status &status);

private:
    void launch();
    void onReady(quint16 port, const QString &token);
    void onProcessFailed(BackendProcess::Failure kind, const QString &detail);
    void onWelcome(const WelcomeInfo &welcome);
    void onClientClosed(const QString &reason);
    void onHandshakeFailed(const QString &code, const QString &message);
    void onRetryTimer();
    void setStatus(Phase phase, const QString &headline, const QString &detail,
                   const QString &serverVersion = {}, const QString &errorCode = {});
    int scaled(int ms) const { return qMax(1, int(ms * m_retryScale)); }
    QString logHint() const;

    enum class RetryAction { None, Reconnect, Relaunch };

    BackendCommand m_command;
    BackendProcess m_process;
    ProtocolClient m_client;
    Status m_status;
    QTimer m_retryTimer;
    RetryAction m_retryAction = RetryAction::None;
    int m_reconnectFailures = 0;
    int m_relaunchFailures = 0;
    bool m_shuttingDown = false;
    double m_retryScale = 1.0;
};

} // namespace qs

Q_DECLARE_METATYPE(qs::BackendConnection::Status)
