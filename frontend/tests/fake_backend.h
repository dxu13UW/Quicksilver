#pragma once
// A scriptable stand-in for the backend gateway, for dashboard tests.
// - Answers `hello` with `welcome` (league configurable) and one `health`.
// - Every other request is recorded in `requests` and left unanswered, unless
//   a handler for its type is set in `handlers`. Tests answer later with
//   reply(), which makes out-of-order replies easy to stage.
// No Q_OBJECT: it only uses lambda connections.

#include "core/protocol_codec.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QTest>
#include <QWebSocket>
#include <QWebSocketServer>

#include <functional>
#include <map>

namespace qs::test {

class FakeBackend : public QObject {
public:
    using Handler = std::function<void(const QJsonObject &msg)>;

    FakeBackend()
    {
        m_ok = m_server.listen(QHostAddress::LocalHost, 0);
        connect(&m_server, &QWebSocketServer::newConnection, this, [this] {
            QWebSocket *s = m_server.nextPendingConnection();
            m_socket = s;
            ++connections;
            connect(s, &QWebSocket::textMessageReceived, this, [this, s](const QString &t) {
                if (s != m_socket)
                    return;
                const QJsonObject msg = QJsonDocument::fromJson(t.toUtf8()).object();
                const QString type = msg.value("type").toString();
                if (type == "hello") {
                    QJsonObject w{{"server_version", "9.9.9"},
                                  {"protocol_version", 1},
                                  {"league", welcomeLeague.isEmpty() ? QJsonValue(QJsonValue::Null)
                                                                     : QJsonValue(welcomeLeague)},
                                  {"features", QJsonObject{{"trade_api_enabled", true}}},
                                  {"health_interval_s", 5}};
                    send("welcome", msg.value("id"), w);
                    send("health", QJsonValue::Null, healthPayload);
                    return;
                }
                requests.append(msg);
                auto it = handlers.find(type.toStdString());
                if (it != handlers.end() && it->second)
                    it->second(msg);
            });
        });
    }

    bool listening() const { return m_ok; }
    quint16 port() const { return m_server.serverPort(); }

    void send(const QString &type, const QJsonValue &id, const QJsonObject &payload)
    {
        if (!m_socket)
            return;
        QJsonObject o{{"type", type}, {"id", id}, {"ts", qs::protocol::timestampNow()}, {"payload", payload}};
        m_socket->sendTextMessage(QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)));
    }
    void reply(const QJsonObject &request, const QString &type, const QJsonObject &payload)
    {
        send(type, request.value("id"), payload);
    }
    void replyError(const QJsonObject &request, const QString &code, const QString &message)
    {
        send("error", request.value("id"), QJsonObject{{"code", code}, {"message", message}});
    }
    void push(const QString &type, const QJsonObject &payload) { send(type, QJsonValue::Null, payload); }
    void dropConnection()
    {
        if (m_socket)
            m_socket->close(QWebSocketProtocol::CloseCodeGoingAway);
    }

    // Requests of one type, in arrival order.
    QList<QJsonObject> requestsOf(const QString &type) const
    {
        QList<QJsonObject> out;
        for (const QJsonObject &r : requests)
            if (r.value("type").toString() == type)
                out.append(r);
        return out;
    }
    int countOf(const QString &type) const { return int(requestsOf(type).size()); }

    QString welcomeLeague = QStringLiteral("Covens");
    QJsonObject healthPayload{{"uptime_s", 3},
                              {"sources", QJsonArray{QJsonObject{{"name", "poe_ninja"}, {"status", "ok"}}}}};
    std::map<std::string, Handler> handlers;
    QList<QJsonObject> requests;
    int connections = 0;

private:
    QWebSocketServer m_server{QStringLiteral("fake"), QWebSocketServer::NonSecureMode};
    QPointer<QWebSocket> m_socket;
    bool m_ok = false;
};

// Payload builders.
inline QJsonObject leaguesResult(const QStringList &ids, const QJsonValue &current)
{
    QJsonArray arr;
    for (const QString &id : ids)
        arr.append(QJsonObject{{"id", id}, {"text", id}});
    return QJsonObject{{"leagues", arr}, {"current", current}};
}

inline QJsonObject rateRow(const QString &id, const QString &name, double chaos, double divineChaos,
                           const QJsonValue &change = QJsonValue::Null, const QJsonValue &volume = QJsonValue::Null)
{
    return QJsonObject{{"id", id},           {"name", name},       {"chaos", chaos},
                       {"divine", chaos / divineChaos}, {"change_7d", change}, {"volume_chaos", volume}};
}

inline QJsonObject ratesUpdate(const QString &league, const QJsonArray &rows, bool stale = false,
                               const QString &fetchedAt = QStringLiteral("2026-11-19T21:00:00.000Z"),
                               double divineChaos = 200.0)
{
    return QJsonObject{{"league", league}, {"source", "poe_ninja"}, {"fetched_at", fetchedAt},
                       {"stale", stale},   {"divine_chaos", divineChaos}, {"rates", rows}};
}

inline QJsonObject sampleRates(const QString &league, bool stale = false)
{
    return ratesUpdate(league,
                       QJsonArray{rateRow("divine", "Divine Orb", 200, 200, -2.1, 120345.6),
                                  rateRow("exalted", "Exalted Orb", 15, 200, 3.5, 5000),
                                  rateRow("alch", "Orb of Alchemy", 0.5, 200, QJsonValue::Null, 800)},
                       stale);
}

inline QJsonObject ratesErrorPush(const QString &league)
{
    return QJsonObject{{"code", "upstream_unavailable"},
                       {"message", "poe.ninja has no prices for this league."},
                       {"topic", "rates"},
                       {"league", league}};
}

} // namespace qs::test
