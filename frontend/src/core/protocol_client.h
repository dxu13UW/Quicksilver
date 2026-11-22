#pragma once
// One WebSocket connection to the backend, speaking PROTOCOL.md v1.
//
// - open(): connects to ws://127.0.0.1:<port>/ws with an EMPTY origin (the
//   backend answers any Origin header with HTTP 403), sends `hello` at once,
//   and emits ready() on `welcome`.
// - request(): sends a message with a fresh "c-<n>" id; the handler runs once,
//   with the reply that echoes that id (an `error` reply included), or with a
//   synthetic "disconnected" error if the connection drops first.
// - Server pushes (id null) come out as pushReceived(); `health` also as
//   healthReceived(). An `error` push with id null comes out as serverError().
// - Handshake failures (an `error` before `welcome`, then close code 1008)
//   come out as handshakeFailed() instead of closed().
//
// It never reconnects by itself; BackendConnection owns that policy.

#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QWebSocket>

#include <functional>
#include <unordered_map>

namespace qs {

struct WelcomeInfo {
    QString serverVersion;
    int protocolVersion = 0;
    QString league; // empty when the backend sent null
    bool tradeApiEnabled = false;
    double healthIntervalS = 0; // seconds; may be fractional (PROTOCOL)
    QJsonObject raw;
};

struct Reply {
    QString type;        // reply type, or "error"
    QJsonObject payload; // for errors: {"code":..., "message":...}
    bool isError() const { return type == QLatin1String("error"); }
    QString errorCode() const { return payload.value(QLatin1String("code")).toString(); }
};

class ProtocolClient : public QObject {
    Q_OBJECT
public:
    enum class State { Idle, Connecting, Handshaking, Ready };
    Q_ENUM(State)

    using ReplyHandler = std::function<void(const Reply &)>;

    explicit ProtocolClient(QString clientVersion, QObject *parent = nullptr);
    ~ProtocolClient() override;

    // Connects and handshakes. Any existing connection is dropped silently.
    void open(quint16 port, const QString &token);
    // Closes without emitting closed(). Pending handlers get "disconnected".
    void close();

    State state() const { return m_state; }
    bool isReady() const { return m_state == State::Ready; }
    const WelcomeInfo &welcome() const { return m_welcome; }

    // Returns the id used, or an empty string if not Ready (handler then gets a
    // "not_connected" error on the next event loop turn).
    QString request(const QString &type, const QJsonObject &payload, ReplyHandler handler);

    // How long to wait for `welcome` after the socket opens.
    void setHandshakeTimeoutMs(int ms) { m_handshakeTimer.setInterval(ms); }

signals:
    void ready(const qs::WelcomeInfo &welcome);
    void healthReceived(const QJsonObject &payload);
    void pushReceived(const QString &type, const QJsonObject &payload);
    // An `error` push (id null). `payload` has any extra fields, e.g. the
    // rates error push's "topic" and "league" (PROTOCOL rates.subscribe).
    void serverError(const QString &code, const QString &message, const QJsonObject &payload);
    void handshakeFailed(const QString &code, const QString &message);
    // The connection ended (or never opened) for a reason other than close()
    // or a handshake failure.
    void closed(const QString &reason);

private:
    void onConnected();
    void onTextMessage(const QString &text);
    void onDisconnected();
    void onSocketError(QAbstractSocket::SocketError error);
    void onHandshakeTimeout();
    void finish(bool emitSignal, const QString &reason);
    void failPending(const QString &code, const QString &message);
    QString nextId();
    void sendRaw(const QString &type, const QString &id, const QJsonObject &payload);

    QString m_clientVersion;
    QWebSocket *m_socket = nullptr;
    State m_state = State::Idle;
    QString m_token;
    QString m_helloId;
    quint64 m_nextId = 1;
    WelcomeInfo m_welcome;
    QString m_handshakeErrorCode;
    QString m_handshakeErrorMessage;
    QString m_lastSocketError;
    QTimer m_handshakeTimer;
    std::unordered_map<std::string, ReplyHandler> m_pending;
};

} // namespace qs

Q_DECLARE_METATYPE(qs::WelcomeInfo)
