#include "core/backend_connection.h"

#include "core/app_log.h"
#include "core/protocol_codec.h"

#include <QDir>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(lcConn, "qs.connection")

namespace qs {

namespace {
constexpr int kMaxReconnects = 5;
constexpr int kMaxRelaunches = 5;
constexpr int kReconnectDelaysMs[] = {500, 1000, 2000, 4000, 5000};
constexpr int kRelaunchDelaysMs[] = {1000, 2000, 4000, 8000, 15000};

template <size_t N>
int delayFor(const int (&table)[N], int attempt)
{
    return table[qBound(0, attempt, int(N) - 1)];
}

QString phaseName(BackendConnection::Phase p)
{
    switch (p) {
    case BackendConnection::Phase::Idle: return QStringLiteral("idle");
    case BackendConnection::Phase::StartingBackend: return QStringLiteral("starting");
    case BackendConnection::Phase::Connecting: return QStringLiteral("connecting");
    case BackendConnection::Phase::Connected: return QStringLiteral("connected");
    case BackendConnection::Phase::Disconnected: return QStringLiteral("disconnected");
    case BackendConnection::Phase::Failed: return QStringLiteral("failed");
    }
    return {};
}
} // namespace

BackendConnection::BackendConnection(BackendCommand command, QObject *parent)
    : QObject(parent), m_command(std::move(command)), m_client(QStringLiteral(QS_CLIENT_VERSION))
{
    qRegisterMetaType<qs::BackendConnection::Status>();
    m_retryTimer.setSingleShot(true);
    connect(&m_retryTimer, &QTimer::timeout, this, &BackendConnection::onRetryTimer);
    connect(&m_process, &BackendProcess::ready, this, &BackendConnection::onReady);
    connect(&m_process, &BackendProcess::failed, this, &BackendConnection::onProcessFailed);
    connect(&m_client, &ProtocolClient::ready, this, &BackendConnection::onWelcome);
    connect(&m_client, &ProtocolClient::closed, this, &BackendConnection::onClientClosed);
    connect(&m_client, &ProtocolClient::handshakeFailed, this, &BackendConnection::onHandshakeFailed);
}

BackendConnection::~BackendConnection()
{
    shutdown();
}

QString BackendConnection::logHint() const
{
    return QStringLiteral("Backend log: %1").arg(QDir::toNativeSeparators(applog::backendLogPath()));
}

void BackendConnection::setStatus(Phase phase, const QString &headline, const QString &detail,
                                  const QString &serverVersion, const QString &errorCode)
{
    m_status = Status{phase, headline, detail, serverVersion, errorCode};
    qCInfo(lcConn).noquote() << "status:" << phaseName(phase) << "|" << headline << "|" << detail;
    emit statusChanged(m_status);
}

void BackendConnection::start()
{
    m_shuttingDown = false;
    launch();
}

void BackendConnection::restart()
{
    m_retryTimer.stop();
    m_retryAction = RetryAction::None;
    m_reconnectFailures = 0;
    m_relaunchFailures = 0;
    m_shuttingDown = false;
    m_client.close();
    m_process.stop();
    launch();
}

void BackendConnection::shutdown()
{
    if (m_shuttingDown)
        return;
    m_shuttingDown = true;
    m_retryTimer.stop();
    m_retryAction = RetryAction::None;
    m_client.close();
    m_process.stop(3000);
    setStatus(Phase::Idle, QStringLiteral("Stopped"), QStringLiteral("The backend has been shut down."));
}

void BackendConnection::launch()
{
    m_client.close();
    setStatus(Phase::StartingBackend, QStringLiteral("Starting the backend…"),
              QStringLiteral("Waiting for it to report ready."));
    m_process.start(m_command);
}

void BackendConnection::onReady(quint16 port, const QString &token)
{
    setStatus(Phase::Connecting, QStringLiteral("Connecting…"),
              QStringLiteral("Backend is up on port %1; saying hello.").arg(port));
    m_client.open(port, token);
}

void BackendConnection::onWelcome(const WelcomeInfo &welcome)
{
    m_reconnectFailures = 0;
    m_relaunchFailures = 0;
    QString detail = QStringLiteral("Backend %1 · protocol %2 · league %3")
                         .arg(welcome.serverVersion)
                         .arg(welcome.protocolVersion)
                         .arg(welcome.league.isEmpty() ? QStringLiteral("not chosen yet") : welcome.league);
    setStatus(Phase::Connected, QStringLiteral("Connected"), detail, welcome.serverVersion);
}

void BackendConnection::onClientClosed(const QString &reason)
{
    if (m_shuttingDown)
        return;
    if (m_process.state() != BackendProcess::State::Ready) {
        // The process side will report (or already reported) what happened.
        return;
    }
    if (m_reconnectFailures >= kMaxReconnects) {
        qCWarning(lcConn) << "reconnect failed" << m_reconnectFailures << "times; restarting the backend";
        m_reconnectFailures = 0;
        m_client.close();
        m_process.stop();
        onProcessFailed(BackendProcess::Failure::Exited,
                        QStringLiteral("the backend stopped answering (%1)").arg(reason));
        return;
    }
    const int delay = delayFor(kReconnectDelaysMs, m_reconnectFailures);
    ++m_reconnectFailures;
    m_retryAction = RetryAction::Reconnect;
    m_retryTimer.start(scaled(delay));
    setStatus(Phase::Disconnected, QStringLiteral("Disconnected"),
              QStringLiteral("Lost the connection (%1). Reconnecting in %2 s.")
                  .arg(reason)
                  .arg(delay / 1000.0));
}

void BackendConnection::onHandshakeFailed(const QString &code, const QString &message)
{
    if (m_shuttingDown)
        return;
    m_retryTimer.stop();
    m_retryAction = RetryAction::None;
    // Leave the process running: it's healthy, it just won't talk to us. The
    // user can Restart; quitting stops it as usual.
    if (code == QLatin1String("protocol_mismatch")) {
        setStatus(Phase::Failed, QStringLiteral("Backend and client versions don't match. Reinstall Quicksilver."),
                  QStringLiteral("%1 (This client speaks protocol %2.)")
                      .arg(message)
                      .arg(protocol::kProtocolVersion),
                  {}, code);
    } else if (code == QLatin1String("unauthorized")) {
        setStatus(Phase::Failed, QStringLiteral("The backend refused this client"),
                  QStringLiteral("%1 Press Restart to launch a fresh backend.").arg(message), {}, code);
    } else {
        setStatus(Phase::Failed, QStringLiteral("The backend rejected the handshake"),
                  QStringLiteral("%1 (%2). %3").arg(message, code, logHint()), {}, code);
    }
}

void BackendConnection::onProcessFailed(BackendProcess::Failure kind, const QString &detail)
{
    if (m_shuttingDown)
        return;
    m_client.close();
    m_retryTimer.stop();
    m_retryAction = RetryAction::None;

    switch (kind) {
    case BackendProcess::Failure::FailedToStart:
        setStatus(Phase::Failed, QStringLiteral("Backend failed to start"),
                  QStringLiteral("%1\n%2").arg(detail, logHint()));
        return;
    case BackendProcess::Failure::ReadyTimeout:
        setStatus(Phase::Failed, QStringLiteral("Backend failed to start"),
                  QStringLiteral("It didn't report ready in time (%1).\n%2").arg(detail, logHint()));
        return;
    case BackendProcess::Failure::VersionMismatch:
        setStatus(Phase::Failed, QStringLiteral("Backend and client versions don't match. Reinstall Quicksilver."),
                  detail, {}, QStringLiteral("protocol_mismatch"));
        return;
    case BackendProcess::Failure::Exited:
        break;
    }

    if (m_relaunchFailures >= kMaxRelaunches) {
        setStatus(Phase::Failed, QStringLiteral("The backend keeps stopping"),
                  QStringLiteral("Gave up after %1 restarts. Last reason: %2.\n%3")
                      .arg(kMaxRelaunches)
                      .arg(detail, logHint()));
        return;
    }
    const int delay = delayFor(kRelaunchDelaysMs, m_relaunchFailures);
    ++m_relaunchFailures;
    m_retryAction = RetryAction::Relaunch;
    m_retryTimer.start(scaled(delay));
    setStatus(Phase::Disconnected, QStringLiteral("Disconnected"),
              QStringLiteral("Backend stopped: %1. Restarting it in %2 s.").arg(detail).arg(delay / 1000.0));
}

void BackendConnection::onRetryTimer()
{
    const RetryAction action = m_retryAction;
    m_retryAction = RetryAction::None;
    if (m_shuttingDown)
        return;
    switch (action) {
    case RetryAction::Reconnect:
        if (m_process.state() == BackendProcess::State::Ready) {
            setStatus(Phase::Connecting, QStringLiteral("Reconnecting…"),
                      QStringLiteral("Backend on port %1; attempt %2.").arg(m_process.port()).arg(m_reconnectFailures));
            m_client.open(m_process.port(), m_process.token());
        }
        break;
    case RetryAction::Relaunch:
        launch();
        break;
    case RetryAction::None:
        break;
    }
}

} // namespace qs
