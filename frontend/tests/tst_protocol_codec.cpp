// PROTOCOL.md v1: READY line, envelope, token.
// Requirements: CON-1 (READY line / launch), CON-2 (envelope + hello),
// NFR-SEC-2 (per-launch random token), NFR-MNT-2 (matches PROTOCOL.md).

#include "core/protocol_codec.h"

#include <QJsonDocument>
#include <QRegularExpression>
#include <QSet>
#include <QTest>

using namespace qs::protocol;

class TestProtocolCodec : public QObject {
    Q_OBJECT
private slots:
    // --- READY line (CON-1) ---
    void ready_valid_data()
    {
        QTest::addColumn<QByteArray>("line");
        QTest::addColumn<int>("port");
        QTest::newRow("plain") << QByteArray(R"(QUICKSILVER_READY {"port":53123,"protocol_version":1})") << 53123;
        QTest::newRow("lf") << QByteArray("QUICKSILVER_READY {\"port\":47474,\"protocol_version\":1}\n") << 47474;
        QTest::newRow("crlf") << QByteArray("QUICKSILVER_READY {\"port\":1,\"protocol_version\":1}\r\n") << 1;
        QTest::newRow("max port") << QByteArray(R"(QUICKSILVER_READY {"port":65535,"protocol_version":1})") << 65535;
    }
    void ready_valid()
    {
        QFETCH(QByteArray, line);
        QFETCH(int, port);
        const auto r = parseReadyLine(line);
        QVERIFY(r.has_value());
        QCOMPARE(int(r->port), port);
        QCOMPARE(r->protocolVersion, 1);
    }

    void ready_invalid_data()
    {
        QTest::addColumn<QByteArray>("line");
        QTest::newRow("empty") << QByteArray();
        QTest::newRow("compile output") << QByteArray("Compiling 12 files (.ex)");
        QTest::newRow("generated") << QByteArray("Generated quicksilver app");
        QTest::newRow("log-ish prefix") << QByteArray(R"(x QUICKSILVER_READY {"port":1,"protocol_version":1})");
        QTest::newRow("trailing junk") << QByteArray(R"(QUICKSILVER_READY {"port":1,"protocol_version":1} x)");
        QTest::newRow("spaces in json") << QByteArray(R"(QUICKSILVER_READY {"port": 1, "protocol_version": 1})");
        QTest::newRow("reordered") << QByteArray(R"(QUICKSILVER_READY {"protocol_version":1,"port":1})");
        QTest::newRow("port 0") << QByteArray(R"(QUICKSILVER_READY {"port":0,"protocol_version":1})");
        QTest::newRow("port too big") << QByteArray(R"(QUICKSILVER_READY {"port":65536,"protocol_version":1})");
        QTest::newRow("port huge") << QByteArray(R"(QUICKSILVER_READY {"port":9999999,"protocol_version":1})");
        QTest::newRow("negative") << QByteArray(R"(QUICKSILVER_READY {"port":-1,"protocol_version":1})");
        QTest::newRow("string port") << QByteArray(R"(QUICKSILVER_READY {"port":"1","protocol_version":1})");
        QTest::newRow("lowercase") << QByteArray(R"(quicksilver_ready {"port":1,"protocol_version":1})");
    }
    void ready_invalid()
    {
        QFETCH(QByteArray, line);
        QVERIFY(!parseReadyLine(line).has_value());
    }

    void ready_otherVersionIsReported()
    {
        // Parsed (so the client can say "versions don't match" at once), but
        // not the supported version.
        const auto r = parseReadyLine(R"(QUICKSILVER_READY {"port":5000,"protocol_version":2})");
        QVERIFY(r.has_value());
        QCOMPARE(r->protocolVersion, 2);
        QVERIFY(r->protocolVersion != kProtocolVersion);
    }

    // --- Envelope decode (CON-2) ---
    void decode_push()
    {
        const auto r = decodeEnvelope(
            R"({"type":"health","id":null,"ts":"2026-11-19T21:04:05.123Z","payload":{"uptime_s":5}})");
        QVERIFY(r.ok());
        QCOMPARE(r.envelope->type, QStringLiteral("health"));
        QVERIFY(r.envelope->isNullId);
        QCOMPARE(r.envelope->payload.value("uptime_s").toInt(), 5);
    }
    void decode_reply()
    {
        const auto r = decodeEnvelope(R"({"type":"welcome","id":"c-1","payload":{}})");
        QVERIFY(r.ok());
        QVERIFY(!r.envelope->isNullId);
        QCOMPARE(r.envelope->id, QStringLiteral("c-1"));
        QVERIFY(r.envelope->payload.isEmpty());
    }
    void decode_missingIdIsNull()
    {
        const auto r = decodeEnvelope(R"({"type":"health","payload":{}})");
        QVERIFY(r.ok());
        QVERIFY(r.envelope->isNullId);
    }
    void decode_ignoresUnknownFieldsAndTs()
    {
        const auto r = decodeEnvelope(
            R"({"type":"x","id":null,"ts":12345,"payload":{"a":1},"extra":[1,2],"v2_field":{"b":true}})");
        QVERIFY(r.ok());
        QCOMPARE(r.envelope->type, QStringLiteral("x"));
        QCOMPARE(r.envelope->payload.value("a").toInt(), 1);
    }

    void decode_invalid_data()
    {
        QTest::addColumn<QByteArray>("frame");
        QTest::newRow("not json") << QByteArray("hello");
        QTest::newRow("truncated") << QByteArray(R"({"type":"x","payload":{})");
        QTest::newRow("array") << QByteArray(R"([{"type":"x","payload":{}}])");
        QTest::newRow("string") << QByteArray(R"("x")");
        QTest::newRow("no type") << QByteArray(R"({"id":null,"payload":{}})");
        QTest::newRow("empty type") << QByteArray(R"({"type":"","payload":{}})");
        QTest::newRow("numeric type") << QByteArray(R"({"type":5,"payload":{}})");
        QTest::newRow("no payload") << QByteArray(R"({"type":"x","id":null})");
        QTest::newRow("payload null") << QByteArray(R"({"type":"x","payload":null})");
        QTest::newRow("payload array") << QByteArray(R"({"type":"x","payload":[]})");
        QTest::newRow("numeric id") << QByteArray(R"({"type":"x","id":5,"payload":{}})");
        QTest::newRow("object id") << QByteArray(R"({"type":"x","id":{},"payload":{}})");
        QTest::newRow("bool id") << QByteArray(R"({"type":"x","id":true,"payload":{}})");
    }
    void decode_invalid()
    {
        QFETCH(QByteArray, frame);
        const auto r = decodeEnvelope(frame);
        QVERIFY(!r.ok());
        QVERIFY(!r.error.reason.isEmpty());
    }

    // --- Envelope encode (CON-2, NFR-MNT-2) ---
    void encode_request()
    {
        QJsonObject payload{{"league", "Covens"}};
        const QByteArray bytes = encodeEnvelope("league.set", "c-7", payload);
        const QJsonObject obj = QJsonDocument::fromJson(bytes).object();
        QCOMPARE(obj.value("type").toString(), QStringLiteral("league.set"));
        QCOMPARE(obj.value("id").toString(), QStringLiteral("c-7"));
        QCOMPARE(obj.value("payload").toObject(), payload);
        QVERIFY(obj.value("ts").isString());
        QCOMPARE(obj.size(), 4);
        // And it decodes back.
        const auto r = decodeEnvelope(bytes);
        QVERIFY(r.ok());
        QCOMPARE(r.envelope->id, QStringLiteral("c-7"));
    }
    void encode_emptyIdIsNullAndPayloadAlwaysPresent()
    {
        const QJsonObject obj = QJsonDocument::fromJson(encodeEnvelope("x", {}, {})).object();
        QVERIFY(obj.value("id").isNull());
        QVERIFY(obj.contains("payload"));
        QVERIFY(obj.value("payload").isObject());
    }
    void timestamp_format()
    {
        static const QRegularExpression re(QStringLiteral(R"(^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$)"));
        for (int i = 0; i < 20; ++i)
            QVERIFY2(re.match(timestampNow()).hasMatch(), qPrintable(timestampNow()));
    }

    // --- hello + token (CON-2, NFR-SEC-2) ---
    void hello_payload()
    {
        const QJsonObject p = helloPayload("0.1.0", "abc");
        QCOMPARE(p.value("client_version").toString(), QStringLiteral("0.1.0"));
        QVERIFY(p.value("protocol_version").isDouble());
        QCOMPARE(p.value("protocol_version").toInt(), 1);
        QCOMPARE(p.value("token").toString(), QStringLiteral("abc"));
    }
    void token_is32HexAndRandom()
    {
        static const QRegularExpression re(QStringLiteral("^[0-9a-f]{32}$"));
        QSet<QString> seen;
        for (int i = 0; i < 100; ++i) {
            const QString t = generateToken();
            QVERIFY2(re.match(t).hasMatch(), qPrintable(t));
            seen.insert(t);
        }
        QCOMPARE(seen.size(), 100);
    }
};

QTEST_GUILESS_MAIN(TestProtocolCodec)
#include "tst_protocol_codec.moc"
