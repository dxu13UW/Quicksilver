#include "core/protocol_client.h"

#include "core/protocol_codec.h"

#include <QLoggingCategory>
#include <QPointer>
#include <QUrl>

Q_LOGGING_CATEGORY(lcProto, "qs.protocol")

namespace qs {

namespace {
QString closeCodeText(QWebSocketProtocol::CloseCode code)
{
    return QString::number(static_cast<int>(code));
}
} // namespace

ProtocolClient::ProtocolClient(QString clientVersion, QObject *parent)
    : QObject(parent), m_clientVersion(std::move(clientVersion))
{
    qRegisterMetaType<qs::WelcomeInfo>();
    m_handshakeTimer.setSingleShot(true);
    m_handshakeTimer.setInterval(10'000);
    connect(&m_handshakeTimer, &QTimer::timeout, this, &ProtocolClient::onHandshakeTimeout);
}

ProtocolClient::~ProtocolClient()
{
    close();
}

void ProtocolClient::open(quint16 port, const QString &token)
{
    close();
    m_token = token;
    m_welcome = {};
    m_handshakeErrorCode.clear();
    m_handshakeErrorMessage.clear();
    m_lastSocketError.clear();

    // Empty origin => no Origin header (PROTOCOL "Origin check").
    m_socket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
    connect(m_socket, &QWebSocket::connected, this, &ProtocolClient::onConnected);
    connect(m_socket, &QWebSocket::textMessageReceived, this, &ProtocolClient::onTextMessage);
    connect(m_socket, &QWebSocket::binaryMessageReceived, this, [](const QByteArray &) {
        qCWarning(lcProto) << "ignoring binary frame from backend";
    });
    connect(m_socket, &QWebSocket::disconnected, this, &ProtocolClient::onDisconnected);
    connect(m_socket, &QWebSocket::errorOccurred, this, &ProtocolClient::onSocketError);

    m_state = State::Connecting;
    m_handshakeTimer.start();
    const QUrl url(QStringLiteral("ws://127.0.0.1:%1/ws").arg(port));
    qCInfo(lcProto) << "connecting to" << url.toString();
    m_socket->open(url);
}

void ProtocolClient::close()
{
    finish(false, QString());
}

void ProtocolClient::finish(bool emitSignal, const QString &reason)
{
    m_handshakeTimer.stop();
    const bool wasActive = m_socket != nullptr;
    if (m_socket) {
        QWebSocket *s = m_socket;
        m_socket = nullptr;
        s->disconnect(this);
        if (s->state() != QAbstractSocket::UnconnectedState)
            s->abort();
        s->deleteLater();
    }
    m_state = State::Idle;
    failPending(QStringLiteral("disconnected"), QStringLiteral("The connection to the backend closed."));
    if (emitSignal && wasActive)
        emit closed(reason);
}

void ProtocolClient::failPending(const QString &code, const QString &message)
{
    if (m_pending.empty())
        return;
    auto pending = std::move(m_pending);
    m_pending.clear();
    Reply r;
    r.type = QStringLiteral("error");
    r.payload.insert(QStringLiteral("code"), code);
    r.payload.insert(QStringLiteral("message"), message);
    for (auto &[id, handler] : pending) {
        if (handler)
            handler(r);
    }
}

QString ProtocolClient::nextId()
{
    return QStringLiteral("c-%1").arg(m_nextId++);
}

void ProtocolClient::sendRaw(const QString &type, const QString &id, const QJsonObject &payload)
{
    if (!m_socket)
        return;
    m_socket->sendTextMessage(QString::fromUtf8(protocol::encodeEnvelope(type, id, payload)));
}

void ProtocolClient::onConnected()
{
    m_state = State::Handshaking;
    m_helloId = nextId();
    qCInfo(lcProto) << "socket open; sending hello" << m_helloId;
    sendRaw(QStringLiteral("hello"), m_helloId, protocol::helloPayload(m_clientVersion, m_token));
}

QString ProtocolClient::request(const QString &type, const QJsonObject &payload, ReplyHandler handler)
{
    if (m_state != State::Ready) {
        if (handler) {
            QMetaObject::invokeMethod(this, [handler] {
                Reply r;
                r.type = QStringLiteral("error");
                r.payload.insert(QStringLiteral("code"), QStringLiteral("not_connected"));
                r.payload.insert(QStringLiteral("message"), QStringLiteral("Not connected to the backend."));
                handler(r);
            }, Qt::QueuedConnection);
        }
        return {};
    }
    const QString id = nextId();
    m_pending.emplace(id.toStdString(), std::move(handler));
    sendRaw(type, id, payload);
    return id;
}

void ProtocolClient::onTextMessage(const QString &text)
{
    const auto decoded = protocol::decodeEnvelope(text.toUtf8());
    if (!decoded.ok()) {
        qCWarning(lcProto) << "dropping undecodable frame:" << decoded.error.reason;
        return;
    }
    const protocol::Envelope &env = *decoded.envelope;

    if (m_state == State::Handshaking) {
        if (env.type == QLatin1String("welcome")) {
            const QJsonObject &p = env.payload;
            m_welcome.serverVersion = p.value(QLatin1String("server_version")).toString();
            m_welcome.protocolVersion = p.value(QLatin1String("protocol_version")).toInt();
            m_welcome.league = p.value(QLatin1String("league")).toString();
            m_welcome.tradeApiEnabled =
                p.value(QLatin1String("features")).toObject().value(QLatin1String("trade_api_enabled")).toBool();
            m_welcome.healthIntervalS = p.value(QLatin1String("health_interval_s")).toInt();
            m_welcome.raw = p;
            m_handshakeTimer.stop();
            m_state = State::Ready;
            qCInfo(lcProto) << "welcome: server" << m_welcome.serverVersion;
            emit ready(m_welcome);
            return;
        }
        if (env.type == QLatin1String("error")) {
            // The server closes with 1008 right after; report on disconnect.
            m_handshakeErrorCode = env.payload.value(QLatin1String("code")).toString();
            m_handshakeErrorMessage = env.payload.value(QLatin1String("message")).toString();
            qCWarning(lcProto) << "handshake rejected:" << m_handshakeErrorCode;
            return;
        }
        qCWarning(lcProto) << "unexpected" << env.type << "before welcome; ignored";
        return;
    }
    if (m_state != State::Ready)
        return;

    if (!env.isNullId) {
        auto it = m_pending.find(env.id.toStdString());
        if (it == m_pending.end()) {
            qCWarning(lcProto) << "reply" << env.type << "for unknown id" << env.id << "; ignored";
            return;
        }
        ReplyHandler handler = std::move(it->second);
        m_pending.erase(it);
        if (handler)
            handler(Reply{env.type, env.payload});
        return;
    }

    if (env.type == QLatin1String("error")) {
        emit serverError(env.payload.value(QLatin1String("code")).toString(),
                         env.payload.value(QLatin1String("message")).toString(), env.payload);
        return;
    }
    if (env.type == QLatin1String("health"))
        emit healthReceived(env.payload);
    emit pushReceived(env.type, env.payload);
}

void ProtocolClient::onDisconnected()
{
    if (!m_socket)
        return;
    const auto code = m_socket->closeCode();
    const QString closeReason = m_socket->closeReason();
    const State was = m_state;

    if (!m_handshakeErrorCode.isEmpty()) {
        const QString code_ = m_handshakeErrorCode;
        const QString msg = m_handshakeErrorMessage;
        finish(false, QString());
        emit handshakeFailed(code_, msg);
        return;
    }

    QString reason;
    if (was == State::Connecting) {
        reason = m_lastSocketError.isEmpty() ? QStringLiteral("could not connect") : m_lastSocketError;
    } else {
        reason = QStringLiteral("connection closed (code %1%2)")
                     .arg(closeCodeText(code),
                          closeReason.isEmpty() ? QString() : QStringLiteral(", ") + closeReason);
    }
    qCInfo(lcProto) << "disconnected:" << reason;
    finish(true, reason);
}

void ProtocolClient::onSocketError(QAbstractSocket::SocketError error)
{
    if (!m_socket)
        return;
    m_lastSocketError = m_socket->errorString();
    qCInfo(lcProto) << "socket error" << error << m_lastSocketError;
    // A failed connect may not be followed by disconnected(); make sure the
    // owner hears about it.
    if (m_state == State::Connecting && m_socket->state() == QAbstractSocket::UnconnectedState)
        QMetaObject::invokeMethod(this, [this, s = QPointer<QWebSocket>(m_socket)] {
            if (s && s == m_socket)
                onDisconnected();
        }, Qt::QueuedConnection);
}

void ProtocolClient::onHandshakeTimeout()
{
    if (m_state == State::Ready || !m_socket)
        return;
    qCWarning(lcProto) << "no welcome within" << m_handshakeTimer.interval() << "ms";
    finish(true, QStringLiteral("no welcome from the backend in time"));
}

} // namespace qs
