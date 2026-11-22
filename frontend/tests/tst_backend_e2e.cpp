// End to end against the real backend (dev build via erl + mix, offline).
// Requirements: CON-1 (start + stop, nothing left running), CON-2 (handshake,
// protocol_mismatch, unauthorized, close 1008), CON-3 (health push),
// CON-4 (backend killed -> disconnected -> restarted and reconnected),
// PROTOCOL "Origin check" (QWebSocket's default sends no Origin; one with an
// Origin is refused), DASH-1/DASH-2/DASH-3 + NFR-UX-3 offline: with no
// network and nothing cached, the dashboard shows its "no data" states
// (upstream_unavailable) instead of failing.
//
// Skips if Erlang/Elixir or backend/ can't be found. Label: integration.

#include "core/backend_connection.h"
#include "core/backend_locator.h"
#include "core/backend_process.h"
#include "core/dashboard.h"
#include "core/protocol_client.h"
#include "core/protocol_codec.h"

#include <QElapsedTimer>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QTest>
#include <QWebSocket>

#ifdef Q_OS_WIN
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

using namespace qs;
using Phase = BackendConnection::Phase;

namespace {
// The first run may compile the backend.
constexpr int kBootMs = 180'000;

bool processGone(qint64 pid, int waitMs)
{
#ifdef Q_OS_WIN
    HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, DWORD(pid));
    if (!h)
        return true;
    const bool gone = WaitForSingleObject(h, waitMs) == WAIT_OBJECT_0;
    CloseHandle(h);
    return gone;
#else
    Q_UNUSED(pid);
    Q_UNUSED(waitMs);
    return true;
#endif
}

void killPid(qint64 pid)
{
#ifdef Q_OS_WIN
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, DWORD(pid));
    if (h) {
        TerminateProcess(h, 9);
        CloseHandle(h);
    }
#endif
}
} // namespace

class TestBackendE2E : public QObject {
    Q_OBJECT
    BackendCommand m_cmd;
    const QHash<QString, QString> m_env{{"QUICKSILVER_OFFLINE", "1"}};

    bool waitPhase(BackendConnection &c, Phase phase, int ms)
    {
        QElapsedTimer t;
        t.start();
        while (c.status().phase != phase && t.elapsed() < ms) {
            if (c.status().phase == Phase::Failed && phase != Phase::Failed)
                return false;
            QTest::qWait(50);
        }
        return c.status().phase == phase;
    }

    // Starts a bare backend and returns once READY is in.
    bool bootProcess(BackendProcess &p)
    {
        p.setExtraEnvironment(m_env);
        p.setReadyTimeoutMs(kBootMs);
        QSignalSpy ready(&p, &BackendProcess::ready);
        p.start(m_cmd);
        return ready.wait(kBootMs);
    }

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        if (!env.contains("QUICKSILVER_BACKEND_DIR"))
            env.insert("QUICKSILVER_BACKEND_DIR", QStringLiteral(QS_BACKEND_DIR));
        env.remove("QUICKSILVER_BACKEND_EXE");
        m_cmd = BackendLocator::resolve(env, {}, {});
        if (!m_cmd.ok())
            QSKIP(qPrintable("backend not runnable here: " + m_cmd.error));
        qInfo().noquote() << "backend command:" << m_cmd.display();
    }

    void launch_connect_health_shutdown()
    {
        BackendConnection conn(m_cmd);
        conn.process()->setExtraEnvironment(m_env);
        conn.process()->setReadyTimeoutMs(kBootMs);
        QSignalSpy health(conn.client(), &ProtocolClient::healthReceived);
        QList<Phase> phases;
        connect(&conn, &BackendConnection::statusChanged, this,
                [&](const BackendConnection::Status &s) { phases << s.phase; });

        conn.start();
        QVERIFY2(waitPhase(conn, Phase::Connected, kBootMs), qPrintable(conn.status().detail));
        QCOMPARE(phases.mid(0, 3), (QList<Phase>{Phase::StartingBackend, Phase::Connecting, Phase::Connected}));
        QVERIFY(!conn.status().serverVersion.isEmpty());
        QVERIFY(conn.process()->jobActive());

        // CON-3: health arrives right after welcome.
        QTRY_VERIFY_WITH_TIMEOUT(!health.isEmpty(), 5000);
        const QJsonObject h = health.first().first().toJsonObject();
        QVERIFY(h.contains("uptime_s"));
        QVERIFY(!h.value("sources").toArray().isEmpty());

        // A request the backend doesn't know yet: unknown_type, connection stays.
        Reply reply;
        conn.client()->request("no.such.type", {}, [&](const Reply &r) { reply = r; });
        QTRY_VERIFY_WITH_TIMEOUT(!reply.type.isEmpty(), 5000);
        QCOMPARE(reply.errorCode(), QStringLiteral("unknown_type"));
        QVERIFY(conn.client()->isReady());

        // CON-1: a normal shutdown (stdin close) leaves nothing running.
        const qint64 pid = conn.process()->processId();
        QVERIFY(pid > 0);
        QElapsedTimer t;
        t.start();
        conn.shutdown();
        qInfo() << "shutdown took" << t.elapsed() << "ms";
        QVERIFY(processGone(pid, 5000));
        // It left because stdin closed, not because the 3 s grace ran out and
        // the job ended it.
        QVERIFY2(t.elapsed() < 2500, "backend ignored stdin EOF");
        QVERIFY(conn.process()->recentLog().join('\n').contains("stdin closed; shutting down"));
        QCOMPARE(conn.status().phase, Phase::Idle);
    }

    void killedBackend_isRestartedAndReconnected() // CON-4
    {
        BackendConnection conn(m_cmd);
        conn.process()->setExtraEnvironment(m_env);
        conn.process()->setReadyTimeoutMs(kBootMs);
        conn.start();
        QVERIFY2(waitPhase(conn, Phase::Connected, kBootMs), qPrintable(conn.status().detail));
        const qint64 pid = conn.process()->processId();

        QElapsedTimer t;
        t.start();
        killPid(pid);
        QVERIFY(waitPhase(conn, Phase::Disconnected, 5000));
        qInfo().noquote() << "after kill:" << conn.status().detail;
        qint64 restartedAt = -1;
        connect(conn.process(), &BackendProcess::ready, this, [&] { restartedAt = t.elapsed(); });
        QVERIFY2(waitPhase(conn, Phase::Connected, kBootMs), qPrintable(conn.status().detail));
        qInfo() << "reconnected" << t.elapsed() << "ms after the kill;" << (t.elapsed() - restartedAt)
                << "ms after the new backend was ready";
        QVERIFY(t.elapsed() - restartedAt < 5000);
        QVERIFY(conn.process()->processId() != pid);
        const qint64 pid2 = conn.process()->processId();
        conn.shutdown();
        QVERIFY(processGone(pid2, 5000));
    }

    void dashboard_offline_noDataStates() // DASH-1, DASH-2, DASH-3, NFR-UX-3
    {
        // QUICKSILVER_OFFLINE=1: no league list, no rates. Nothing is saved:
        // league.set is refused before the settings file is touched.
        BackendProcess proc;
        QVERIFY(bootProcess(proc));
        ProtocolClient client("0.1.0");
        Dashboard dash;
        dash.attach(&client);
        client.open(proc.port(), proc.token());

        LeagueController *lc = dash.leagues();
        RatesFeed *rates = dash.rates();
        QTRY_VERIFY_WITH_TIMEOUT(lc->listState() == LeagueController::ListState::Unavailable, 30000);
        qInfo().noquote() << "leagues.list:" << lc->listError() << "| current:" << lc->current();
        QVERIFY(!lc->listError().isEmpty());
        QVERIFY(lc->leagues().isEmpty());

        QTRY_COMPARE_WITH_TIMEOUT(rates->state(), RatesFeed::State::Error, 30000);
        qInfo().noquote() << "rates:" << rates->errorCode() << rates->message();
        QCOMPARE(rates->errorCode(), QStringLiteral("upstream_unavailable"));
        QVERIFY(!rates->message().isEmpty());
        QCOMPARE(rates->model()->rowCount(), 0);

        // CON-3/DASH-3: health arrives and names the sources.
        QTRY_VERIFY_WITH_TIMEOUT(dash.health()->hasReport(), 10000);
        QVERIFY(dash.health()->rowCount() >= 1);
        qInfo().noquote() << "health:" << dash.health()->summary();

        // DASH-2: a change can't be checked without the list -> error, revert.
        QSignalSpy failed(lc, &LeagueController::changeFailed);
        const QString before = lc->current();
        const QString target = before == QLatin1String("Standard") ? QStringLiteral("Hardcore") : QStringLiteral("Standard");
        QVERIFY(lc->select(target));
        QVERIFY(failed.wait(30000));
        QCOMPARE(failed.first().at(1).toString(), QStringLiteral("upstream_unavailable"));
        QCOMPARE(lc->current(), before);
        QVERIFY(client.isReady());

        client.close();
        const qint64 pid = proc.processId();
        proc.stop();
        QVERIFY(processGone(pid, 5000));
    }

    void handshakeRejections() // CON-2
    {
        BackendProcess proc;
        QVERIFY(bootProcess(proc));

        // Wrong token -> unauthorized, then close.
        {
            ProtocolClient client("0.1.0");
            QSignalSpy failed(&client, &ProtocolClient::handshakeFailed);
            client.open(proc.port(), protocol::generateToken());
            QVERIFY(failed.wait(10000));
            QCOMPARE(failed.first().first().toString(), QStringLiteral("unauthorized"));
        }

        // Another protocol version -> protocol_mismatch with expected: 1, close 1008.
        {
            QWebSocket ws; // default origin: none
            QSignalSpy connected(&ws, &QWebSocket::connected);
            QSignalSpy text(&ws, &QWebSocket::textMessageReceived);
            QSignalSpy disconnected(&ws, &QWebSocket::disconnected);
            ws.open(QUrl(QStringLiteral("ws://127.0.0.1:%1/ws").arg(proc.port())));
            QVERIFY(connected.wait(10000));
            QJsonObject hello = protocol::helloPayload("0.1.0", proc.token());
            hello.insert("protocol_version", 2);
            ws.sendTextMessage(QString::fromUtf8(protocol::encodeEnvelope("hello", "c-1", hello)));
            QVERIFY(text.wait(10000));
            const auto env = protocol::decodeEnvelope(text.first().first().toString().toUtf8());
            QVERIFY(env.ok());
            QCOMPARE(env.envelope->type, QStringLiteral("error"));
            QCOMPARE(env.envelope->id, QStringLiteral("c-1"));
            QCOMPARE(env.envelope->payload.value("code").toString(), QStringLiteral("protocol_mismatch"));
            QCOMPARE(env.envelope->payload.value("expected").toInt(), 1);
            QTRY_VERIFY_WITH_TIMEOUT(!disconnected.isEmpty(), 10000);
            QCOMPARE(ws.closeCode(), QWebSocketProtocol::CloseCodePolicyViolated);
        }

        // An Origin header is refused (HTTP 403); our client's empty origin is not.
        {
            QWebSocket ws(QStringLiteral("http://example.invalid"));
            QSignalSpy connected(&ws, &QWebSocket::connected);
            QSignalSpy error(&ws, &QWebSocket::errorOccurred);
            ws.open(QUrl(QStringLiteral("ws://127.0.0.1:%1/ws").arg(proc.port())));
            QTRY_VERIFY_WITH_TIMEOUT(!error.isEmpty(), 10000);
            QVERIFY(connected.isEmpty());
            qInfo().noquote() << "with Origin:" << ws.errorString();
        }
        {
            ProtocolClient client("0.1.0");
            QSignalSpy ready(&client, &ProtocolClient::ready);
            client.open(proc.port(), proc.token());
            QVERIFY(ready.wait(10000));
        }

        const qint64 pid = proc.processId();
        proc.stop();
        QVERIFY(processGone(pid, 5000));
    }
};

QTEST_GUILESS_MAIN(TestBackendE2E)
#include "tst_backend_e2e.moc"
