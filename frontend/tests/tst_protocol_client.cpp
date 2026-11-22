// ProtocolClient against an in-process fake backend.
// Requirements: CON-2 (hello/welcome, protocol_mismatch, unauthorized + 1008),
// CON-3 (health pushes reach the client), NFR-SEC-2 (token in hello),
// PROTOCOL "Origin check" (no Origin header), NFR-MNT-2.

#include "core/protocol_client.h"
#include "core/protocol_codec.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QPointer>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTest>
#include <QWebSocket>
#include <QWebSocketServer>

#include <functional>

using namespace qs;

namespace {

QJsonObject parse(const QString &text)
{
    return QJsonDocument::fromJson(text.toUtf8()).object();
}

// A scripted stand-in for the backend gateway.
class FakeBackend : public QObject {
    Q_OBJECT
public:
    using Script = std::function<void(QWebSocket *, const QJsonObject &)>;

    FakeBackend()
    {
        QVERIFY(m_server.listen(QHostAddress::LocalHost, 0));
        connect(&m_server, &QWebSocketServer::newConnection, this, [this] {
            QWebSocket *s = m_server.nextPendingConnection();
            m_socket = s;
            origins.append(s->origin());
            connect(s, &QWebSocket::textMessageReceived, this, [this, s](const QString &t) {
                const QJsonObject msg = parse(t);
                received.append(msg);
                if (script)
                    script(s, msg);
            });
        });
    }
    quint16 port() const { return m_server.serverPort(); }
    QWebSocket *socket() const { return m_socket; }

    static void send(QWebSocket *s, const QString &type, const QJsonValue &id, const QJsonObject &payload)
    {
        QJsonObject o{{"type", type}, {"id", id}, {"ts", qs::protocol::timestampNow()}, {"payload", payload}};
        s->sendTextMessage(QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)));
    }
    static QJsonObject welcomePayload()
    {
        return QJsonObject{{"server_version", "9.8.7"},
                           {"protocol_version", 1},
                           {"league", "Covens"},
                           {"features", QJsonObject{{"trade_api_enabled", true}}},
                           {"health_interval_s", 5}};
    }
    // Welcomes any hello, like the real gateway.
    void acceptHello()
    {
        script = [](QWebSocket *s, const QJsonObject &m) {
            if (m.value("type") == "hello") {
                send(s, "welcome", m.value("id"), welcomePayload());
                send(s, "health", QJsonValue::Null,
                     QJsonObject{{"uptime_s", 1},
                                 {"sources", QJsonArray{QJsonObject{{"name", "poe_ninja"}, {"status", "idle"}}}}});
            }
        };
    }

    Script script;
    QList<QJsonObject> received;
    QStringList origins;

private:
    QWebSocketServer m_server{QStringLiteral("fake"), QWebSocketServer::NonSecureMode};
    QPointer<QWebSocket> m_socket;
};

} // namespace

class TestProtocolClient : public QObject {
    Q_OBJECT
private slots:
    void hello_carriesTokenVersionAndId()
    {
        FakeBackend fake;
        fake.acceptHello();
        ProtocolClient client("0.1.0");
        QSignalSpy ready(&client, &ProtocolClient::ready);
        client.open(fake.port(), "0123456789abcdef0123456789abcdef");
        QVERIFY(ready.wait(5000));

        QCOMPARE(fake.received.size(), 1);
        const QJsonObject hello = fake.received.first();
        QCOMPARE(hello.value("type").toString(), QStringLiteral("hello"));
        QCOMPARE(hello.value("id").toString(), QStringLiteral("c-1"));
        QVERIFY(hello.value("ts").isString());
        const QJsonObject p = hello.value("payload").toObject();
        QCOMPARE(p.value("token").toString(), QStringLiteral("0123456789abcdef0123456789abcdef"));
        QCOMPARE(p.value("protocol_version").toInt(), 1);
        QCOMPARE(p.value("client_version").toString(), QStringLiteral("0.1.0"));
        // The server saw no origin.
        QCOMPARE(fake.origins, QStringList{QString()});
    }

    void upgradeRequest_hasNoOriginHeader()
    {
        // Raw TCP so we see the exact bytes of the HTTP upgrade request.
        QTcpServer tcp;
        QVERIFY(tcp.listen(QHostAddress::LocalHost, 0));
        ProtocolClient client("0.1.0");
        client.open(tcp.serverPort(), "t");
        QVERIFY(tcp.waitForNewConnection(5000));
        QTcpSocket *s = tcp.nextPendingConnection();
        QByteArray request;
        QTRY_VERIFY_WITH_TIMEOUT((request += s->readAll(), request.contains("\r\n\r\n")), 5000);
        QVERIFY2(request.startsWith("GET /ws HTTP/1.1\r\n"), request.constData());
        QVERIFY2(!request.toLower().contains("\norigin:"), request.constData());
        QVERIFY(request.toLower().contains("\nhost: 127.0.0.1:"));
        client.close();
    }

    void welcome_and_health()
    {
        FakeBackend fake;
        fake.acceptHello();
        ProtocolClient client("0.1.0");
        QSignalSpy ready(&client, &ProtocolClient::ready);
        QSignalSpy health(&client, &ProtocolClient::healthReceived);
        QSignalSpy push(&client, &ProtocolClient::pushReceived);
        client.open(fake.port(), "t");
        QVERIFY(ready.wait(5000));
        QVERIFY(client.isReady());
        const auto w = ready.first().first().value<WelcomeInfo>();
        QCOMPARE(w.serverVersion, QStringLiteral("9.8.7"));
        QCOMPARE(w.protocolVersion, 1);
        QCOMPARE(w.league, QStringLiteral("Covens"));
        QVERIFY(w.tradeApiEnabled);
        QCOMPARE(w.healthIntervalS, 5.0);

        QTRY_COMPARE_WITH_TIMEOUT(health.size(), 1, 5000);
        const QJsonObject h = health.first().first().toJsonObject();
        QCOMPARE(h.value("sources").toArray().first().toObject().value("name").toString(),
                 QStringLiteral("poe_ninja"));
        QCOMPARE(push.size(), 1);
        QCOMPARE(push.first().first().toString(), QStringLiteral("health"));
    }

    void welcome_nullLeague()
    {
        FakeBackend fake;
        fake.script = [](QWebSocket *s, const QJsonObject &m) {
            QJsonObject p = FakeBackend::welcomePayload();
            p.insert("league", QJsonValue::Null);
            p.insert("health_interval_s", 0.25); // a number, may be fractional
            FakeBackend::send(s, "welcome", m.value("id"), p);
        };
        ProtocolClient client("0.1.0");
        QSignalSpy ready(&client, &ProtocolClient::ready);
        client.open(fake.port(), "t");
        QVERIFY(ready.wait(5000));
        QVERIFY(client.welcome().league.isEmpty());
        QCOMPARE(client.welcome().healthIntervalS, 0.25);
    }

    void requests_matchedById_outOfOrder()
    {
        FakeBackend fake;
        QList<QJsonObject> held;
        fake.script = [&held](QWebSocket *s, const QJsonObject &m) {
            if (m.value("type") == "hello") {
                FakeBackend::send(s, "welcome", m.value("id"), FakeBackend::welcomePayload());
                return;
            }
            held.append(m);
            if (held.size() == 2) {
                // Answer the second request first, then the first one with an error.
                FakeBackend::send(s, "leagues.result", held[1].value("id"), QJsonObject{{"n", 2}});
                FakeBackend::send(s, "error", held[0].value("id"),
                                  QJsonObject{{"code", "unknown_league"}, {"message", "nope"}});
            }
        };
        ProtocolClient client("0.1.0");
        QSignalSpy ready(&client, &ProtocolClient::ready);
        client.open(fake.port(), "t");
        QVERIFY(ready.wait(5000));

        Reply first, second;
        int calls = 0;
        const QString id1 = client.request("league.set", {{"league", "Foo"}}, [&](const Reply &r) { first = r; ++calls; });
        const QString id2 = client.request("leagues.list", {}, [&](const Reply &r) { second = r; ++calls; });
        QCOMPARE(id1, QStringLiteral("c-2")); // c-1 was the hello
        QCOMPARE(id2, QStringLiteral("c-3"));
        QTRY_COMPARE_WITH_TIMEOUT(calls, 2, 5000);
        QVERIFY(first.isError());
        QCOMPARE(first.errorCode(), QStringLiteral("unknown_league"));
        QCOMPARE(second.type, QStringLiteral("leagues.result"));
        QCOMPARE(second.payload.value("n").toInt(), 2);
        QCOMPARE(held[0].value("payload").toObject().value("league").toString(), QStringLiteral("Foo"));
    }

    void unknownIdReply_ignored_and_errorPush_reported()
    {
        FakeBackend fake;
        fake.script = [](QWebSocket *s, const QJsonObject &m) {
            FakeBackend::send(s, "welcome", m.value("id"), FakeBackend::welcomePayload());
            FakeBackend::send(s, "leagues.result", "c-999", {});
            FakeBackend::send(s, "garbage", 5, {}); // invalid id: dropped
            FakeBackend::send(s, "error", QJsonValue::Null, QJsonObject{{"code", "upstream_unavailable"}, {"message", "m"},
                                                                          {"topic", "rates"}, {"league", "Ruthless"}});
        };
        ProtocolClient client("0.1.0");
        QSignalSpy err(&client, &ProtocolClient::serverError);
        QSignalSpy push(&client, &ProtocolClient::pushReceived);
        QSignalSpy closed(&client, &ProtocolClient::closed);
        client.open(fake.port(), "t");
        QVERIFY(err.wait(5000));
        QCOMPARE(err.first().first().toString(), QStringLiteral("upstream_unavailable"));
        QCOMPARE(err.first().at(2).toJsonObject().value("topic").toString(), QStringLiteral("rates"));
        QCOMPARE(err.first().at(2).toJsonObject().value("league").toString(), QStringLiteral("Ruthless"));
        QCOMPARE(push.size(), 0);
        QCOMPARE(closed.size(), 0);
        QVERIFY(client.isReady());
    }

    void handshake_rejected_data()
    {
        QTest::addColumn<QString>("code");
        QTest::newRow("protocol_mismatch") << QStringLiteral("protocol_mismatch");
        QTest::newRow("unauthorized") << QStringLiteral("unauthorized");
        QTest::newRow("bad_request") << QStringLiteral("bad_request");
    }
    void handshake_rejected()
    {
        QFETCH(QString, code);
        FakeBackend fake;
        fake.script = [code](QWebSocket *s, const QJsonObject &m) {
            QJsonObject p{{"code", code}, {"message", "rejected"}};
            if (code == "protocol_mismatch")
                p.insert("expected", 1);
            FakeBackend::send(s, "error", m.value("id"), p);
            s->close(QWebSocketProtocol::CloseCodePolicyViolated);
        };
        ProtocolClient client("0.1.0");
        QSignalSpy failed(&client, &ProtocolClient::handshakeFailed);
        QSignalSpy closed(&client, &ProtocolClient::closed);
        QSignalSpy ready(&client, &ProtocolClient::ready);
        client.open(fake.port(), "t");
        QVERIFY(failed.wait(5000));
        QCOMPARE(failed.first().at(0).toString(), code);
        QCOMPARE(failed.first().at(1).toString(), QStringLiteral("rejected"));
        QCOMPARE(closed.size(), 0);
        QCOMPARE(ready.size(), 0);
        QCOMPARE(client.state(), ProtocolClient::State::Idle);
    }

    void serverClose_failsPendingAndEmitsClosed()
    {
        FakeBackend fake;
        fake.script = [](QWebSocket *s, const QJsonObject &m) {
            if (m.value("type") == "hello")
                FakeBackend::send(s, "welcome", m.value("id"), FakeBackend::welcomePayload());
            else
                s->close(QWebSocketProtocol::CloseCodeGoingAway); // never answers
        };
        ProtocolClient client("0.1.0");
        QSignalSpy ready(&client, &ProtocolClient::ready);
        QSignalSpy closed(&client, &ProtocolClient::closed);
        client.open(fake.port(), "t");
        QVERIFY(ready.wait(5000));
        Reply got;
        client.request("rates.subscribe", {}, [&](const Reply &r) { got = r; });
        QVERIFY(closed.wait(5000));
        QVERIFY(got.isError());
        QCOMPARE(got.errorCode(), QStringLiteral("disconnected"));
        QVERIFY(closed.first().first().toString().contains("1001"));
    }

    void connectRefused_emitsClosed()
    {
        quint16 port;
        {
            QTcpServer t;
            QVERIFY(t.listen(QHostAddress::LocalHost, 0));
            port = t.serverPort();
        } // closed: nothing listens there now
        ProtocolClient client("0.1.0");
        QSignalSpy closed(&client, &ProtocolClient::closed);
        client.open(port, "t");
        QVERIFY(closed.wait(10000));
        QCOMPARE(closed.size(), 1);
    }

    void handshakeTimeout_emitsClosed()
    {
        FakeBackend fake; // never answers hello
        ProtocolClient client("0.1.0");
        client.setHandshakeTimeoutMs(300);
        QSignalSpy closed(&client, &ProtocolClient::closed);
        client.open(fake.port(), "t");
        QVERIFY(closed.wait(5000));
        QVERIFY(closed.first().first().toString().contains("welcome"));
    }

    void request_beforeReady_failsAsync()
    {
        ProtocolClient client("0.1.0");
        Reply got;
        bool called = false;
        const QString id = client.request("leagues.list", {}, [&](const Reply &r) { got = r; called = true; });
        QVERIFY(id.isEmpty());
        QVERIFY(!called); // not re-entrant
        QTRY_VERIFY(called);
        QCOMPARE(got.errorCode(), QStringLiteral("not_connected"));
    }

    void close_isSilent()
    {
        FakeBackend fake;
        fake.acceptHello();
        ProtocolClient client("0.1.0");
        QSignalSpy ready(&client, &ProtocolClient::ready);
        QSignalSpy closed(&client, &ProtocolClient::closed);
        client.open(fake.port(), "t");
        QVERIFY(ready.wait(5000));
        client.close();
        QTest::qWait(200);
        QCOMPARE(closed.size(), 0);
        QCOMPARE(client.state(), ProtocolClient::State::Idle);
    }
};

QTEST_GUILESS_MAIN(TestProtocolClient)
#include "tst_protocol_client.moc"
