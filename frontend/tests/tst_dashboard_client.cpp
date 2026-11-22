// Dashboard (LeagueController + RatesFeed + HealthModel) against a fake
// backend over a real WebSocket.
// Requirements: DASH-1 (rates.subscribe / rates.update / rates error push),
// DASH-2 (leagues.list fills the selector, league.set on selection, revert on
// error, filling never sends league.set), DASH-3 + CON-3 (health report),
// CON-4 (re-subscribe after reconnect), NFR-REL-3 (stale flag; last data kept
// while disconnected), NFR-MNT-2 (messages per PROTOCOL v1, replies matched
// by id in any order).

#include "core/dashboard.h"
#include "core/protocol_client.h"
#include "fake_backend.h"

#include <QSignalSpy>
#include <QTest>

using namespace qs;
using namespace qs::test;
using LS = LeagueController::ListState;
using RS = RatesFeed::State;

namespace {
struct Rig {
    FakeBackend fake;
    ProtocolClient client{QStringLiteral("0.1.0")};
    Dashboard dash;

    Rig() { dash.attach(&client); }

    // Connects and waits until the dashboard has sent its two requests.
    bool connect()
    {
        const int before = fake.countOf("rates.subscribe");
        client.open(fake.port(), QStringLiteral("t"));
        return QTest::qWaitFor([&] { return fake.countOf("rates.subscribe") > before && client.isReady(); }, 5000);
    }
    QJsonObject last(const QString &type) const { return fake.requestsOf(type).last(); }

    // Connected, list loaded (Standard, Covens, Ruthless Covens; current
    // Covens) and Covens rates shown.
    bool connectLoaded()
    {
        if (!connect())
            return false;
        fake.reply(last("leagues.list"), "leagues.result",
                   leaguesResult({"Covens", "Standard", "Ruthless Covens"}, "Covens"));
        fake.reply(last("rates.subscribe"), "rates.update", sampleRates("Covens"));
        return QTest::qWaitFor([&] {
            return dash.leagues()->listState() == LS::Loaded && dash.rates()->state() == RS::Ready;
        }, 5000);
    }
};
} // namespace

class TestDashboardClient : public QObject {
    Q_OBJECT
private slots:
    void initialState()
    {
        Dashboard d;
        QCOMPARE(d.leagues()->listState(), LS::NotLoaded);
        QVERIFY(!d.leagues()->connected());
        QCOMPARE(d.rates()->state(), RS::Waiting);
        QVERIFY(!d.health()->hasReport());
        QVERIFY(!d.leagues()->select("Standard")); // nothing to send on
    }

    void welcome_requestsLeaguesAndSubscribes()
    {
        Rig rig;
        QVERIFY(rig.fake.listening());
        QVERIFY(rig.connect());
        QCOMPARE(rig.fake.countOf("leagues.list"), 1);
        QCOMPARE(rig.fake.countOf("rates.subscribe"), 1);
        QCOMPARE(rig.last("leagues.list").value("payload").toObject(), QJsonObject{});
        QCOMPARE(rig.last("rates.subscribe").value("payload").toObject(), QJsonObject{});
        // welcome.league is the active league until the list arrives.
        QCOMPARE(rig.dash.leagues()->current(), QStringLiteral("Covens"));
        QCOMPARE(rig.dash.leagues()->listState(), LS::Loading);
        QCOMPARE(rig.dash.rates()->state(), RS::Loading);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Covens"));
        QVERIFY(rig.dash.rates()->live());
    }

    void leaguesResult_fillsList_withoutLeagueSet()
    {
        Rig rig;
        QVERIFY(rig.connect());
        QSignalSpy current(rig.dash.leagues(), &LeagueController::currentChanged);
        rig.fake.reply(rig.last("leagues.list"), "leagues.result",
                       leaguesResult({"Covens", "Standard", "Hardcore Covens"}, "Standard"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.leagues()->listState(), LS::Loaded, 5000);
        QCOMPARE(rig.dash.leagues()->leagues().size(), 3);
        QCOMPARE(rig.dash.leagues()->leagues().at(2).id, QStringLiteral("Hardcore Covens"));
        // leagues.result.current wins over welcome.league.
        QCOMPARE(rig.dash.leagues()->current(), QStringLiteral("Standard"));
        QCOMPARE(current.size(), 1);
        QTest::qWait(100);
        QCOMPARE(rig.fake.countOf("league.set"), 0);
    }

    void leaguesResult_nullCurrent()
    {
        Rig rig;
        rig.fake.welcomeLeague.clear(); // welcome.league null
        QVERIFY(rig.connect());
        QCOMPARE(rig.dash.leagues()->current(), QString());
        rig.fake.reply(rig.last("leagues.list"), "leagues.result",
                       leaguesResult({"Standard"}, QJsonValue(QJsonValue::Null)));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.leagues()->listState(), LS::Loaded, 5000);
        QCOMPARE(rig.dash.leagues()->current(), QString());
    }

    void leaguesList_unavailable()
    {
        Rig rig;
        QVERIFY(rig.connect());
        rig.fake.replyError(rig.last("leagues.list"), "upstream_unavailable", "The league list can't be fetched.");
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.leagues()->listState(), LS::Unavailable, 5000);
        QCOMPARE(rig.dash.leagues()->listError(), QStringLiteral("The league list can't be fetched."));
        QCOMPARE(rig.dash.leagues()->current(), QStringLiteral("Covens")); // from welcome
        // Reload asks again.
        rig.dash.leagues()->reload();
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("leagues.list"), 2, 5000);
        QCOMPARE(rig.dash.leagues()->listState(), LS::Loading);
    }

    void select_sendsLeagueSet_thenLoadsNewRates()
    {
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        QSignalSpy ok(lc, &LeagueController::changeSucceeded);

        QVERIFY(lc->select("Standard"));
        QVERIFY(lc->isPending());
        QCOMPARE(lc->pending(), QStringLiteral("Standard"));
        QCOMPARE(lc->current(), QStringLiteral("Covens"));
        QVERIFY(!lc->select("Ruthless Covens")); // one change at a time
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        QCOMPARE(rig.last("league.set").value("payload").toObject(), (QJsonObject{{"league", "Standard"}}));

        rig.fake.reply(rig.last("league.set"), "league.changed", QJsonObject{{"league", "Standard"}});
        QVERIFY(ok.wait(5000));
        QCOMPARE(ok.first().first().toString(), QStringLiteral("Standard"));
        QCOMPARE(lc->current(), QStringLiteral("Standard"));
        QVERIFY(!lc->isPending());
        // The old league's rows are gone while the new league loads.
        QCOMPARE(rig.dash.rates()->state(), RS::Loading);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Standard"));
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 0);

        rig.fake.push("rates.update", sampleRates("Standard"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Ready, 5000);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Standard"));
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 3);
        QCOMPARE(rig.fake.countOf("league.set"), 1);
    }

    void select_sameLeague_sendsNothing()
    {
        Rig rig;
        QVERIFY(rig.connectLoaded());
        QVERIFY(!rig.dash.leagues()->select("Covens"));
        QVERIFY(!rig.dash.leagues()->select(QString()));
        QTest::qWait(100);
        QCOMPARE(rig.fake.countOf("league.set"), 0);
    }

    void select_error_revertsToPrevious_data()
    {
        QTest::addColumn<QString>("code");
        QTest::newRow("unknown_league") << QStringLiteral("unknown_league");
        QTest::newRow("upstream_unavailable") << QStringLiteral("upstream_unavailable");
        QTest::newRow("internal") << QStringLiteral("internal");
    }
    void select_error_revertsToPrevious()
    {
        QFETCH(QString, code);
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        QSignalSpy failed(lc, &LeagueController::changeFailed);
        QSignalSpy ok(lc, &LeagueController::changeSucceeded);
        QVERIFY(lc->select("Ruthless Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        rig.fake.replyError(rig.last("league.set"), code, "Nope.");
        QVERIFY(failed.wait(5000));
        QCOMPARE(failed.first().at(0).toString(), QStringLiteral("Ruthless Covens"));
        QCOMPARE(failed.first().at(1).toString(), code);
        QCOMPARE(failed.first().at(2).toString(), QStringLiteral("Nope."));
        QCOMPARE(ok.size(), 0);
        QCOMPARE(lc->current(), QStringLiteral("Covens"));
        QVERIFY(!lc->isPending());
        // Rates untouched.
        QCOMPARE(rig.dash.rates()->state(), RS::Ready);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Covens"));
        // A new choice is possible again.
        QVERIFY(lc->select("Standard"));
    }

    void outOfOrder_oldListDoesNotUndoChange()
    {
        // leagues.list (current = Covens) is still out when league.set
        // succeeds; its late reply must not move current back.
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        lc->reload();
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("leagues.list"), 2, 5000);
        const QJsonObject listReq = rig.last("leagues.list");
        QVERIFY(lc->select("Standard"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        rig.fake.reply(rig.last("league.set"), "league.changed", QJsonObject{{"league", "Standard"}});
        rig.fake.reply(listReq, "leagues.result", leaguesResult({"Covens", "Standard", "Ruthless Covens", "Necropolis"}, "Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(lc->leagues().size(), 4, 5000);
        QCOMPARE(lc->leagues().at(3).id, QStringLiteral("Necropolis")); // list applied
        QCOMPARE(lc->current(), QStringLiteral("Standard"));            // current not reverted
    }

    void leagueChangedPush_selectsLeague_sendsNothing()
    {
        // PROTOCOL "league.changed push": the backend picked a league itself.
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        QSignalSpy backend(lc, &LeagueController::backendChanged);
        QSignalSpy ok(lc, &LeagueController::changeSucceeded);
        rig.fake.push("league.changed", QJsonObject{{"league", "Standard"}});
        QVERIFY(backend.wait(5000));
        QCOMPARE(backend.first().first().toString(), QStringLiteral("Standard"));
        QCOMPARE(lc->current(), QStringLiteral("Standard"));
        QCOMPARE(ok.size(), 0);
        // The rates feed loads the new league, as after a user switch.
        QCOMPARE(rig.dash.rates()->state(), RS::Loading);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Standard"));
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 0);
        rig.fake.push("rates.update", sampleRates("Standard"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Ready, 5000);
        // A push for the league already shown changes nothing.
        rig.fake.push("league.changed", QJsonObject{{"league", "Standard"}});
        QTest::qWait(150);
        QCOMPARE(backend.size(), 1);
        QCOMPARE(rig.dash.rates()->state(), RS::Ready);
        QCOMPARE(rig.fake.countOf("league.set"), 0);
    }

    void leagueChangedPush_beforeOldListReply_wins()
    {
        // A leagues.result requested before the push carries the old current.
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        lc->reload();
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("leagues.list"), 2, 5000);
        rig.fake.push("league.changed", QJsonObject{{"league", "Standard"}});
        rig.fake.reply(rig.last("leagues.list"), "leagues.result",
                       leaguesResult({"Covens", "Standard", "Ruthless Covens"}, "Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(lc->listState(), LS::Loaded, 5000);
        QCOMPARE(lc->current(), QStringLiteral("Standard"));
    }

    void leagueChangedPush_duringPendingSet_keepsUserChoice_success()
    {
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        QSignalSpy backend(lc, &LeagueController::backendChanged);
        QVERIFY(lc->select("Ruthless Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        rig.fake.push("league.changed", QJsonObject{{"league", "Standard"}});
        QTRY_COMPARE_WITH_TIMEOUT(lc->current(), QStringLiteral("Standard"), 5000);
        // The user's choice stays pending and shown; no backend note.
        QVERIFY(lc->isPending());
        QCOMPARE(lc->pending(), QStringLiteral("Ruthless Covens"));
        QCOMPARE(backend.size(), 0);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Covens")); // not switched by the push
        // The reply decides.
        rig.fake.reply(rig.last("league.set"), "league.changed", QJsonObject{{"league", "Ruthless Covens"}});
        QTRY_VERIFY_WITH_TIMEOUT(!lc->isPending(), 5000);
        QCOMPARE(lc->current(), QStringLiteral("Ruthless Covens"));
        QCOMPARE(rig.dash.rates()->state(), RS::Loading);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Ruthless Covens"));
        QCOMPARE(rig.fake.countOf("league.set"), 1);
    }

    void leagueChangedPush_duringPendingSet_errorRevertsToPushed()
    {
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        QSignalSpy failed(lc, &LeagueController::changeFailed);
        QVERIFY(lc->select("Ruthless Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        rig.fake.push("league.changed", QJsonObject{{"league", "Standard"}});
        QTRY_COMPARE_WITH_TIMEOUT(lc->current(), QStringLiteral("Standard"), 5000);
        rig.fake.replyError(rig.last("league.set"), "unknown_league", "Nope.");
        QVERIFY(failed.wait(5000));
        // Reverts to the backend's real league, and the rates follow it.
        QCOMPARE(lc->current(), QStringLiteral("Standard"));
        QVERIFY(!lc->isPending());
        QCOMPARE(rig.dash.rates()->state(), RS::Loading);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Standard"));
        QCOMPARE(rig.fake.countOf("league.set"), 1);
    }

    void subscribeReply_showsRates_withStaleFlag()
    {
        Rig rig;
        QVERIFY(rig.connect());
        QSignalSpy changed(rig.dash.rates(), &RatesFeed::changed);
        rig.fake.reply(rig.last("rates.subscribe"), "rates.update", sampleRates("Covens", true));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Ready, 5000);
        const RatesFeed *f = rig.dash.rates();
        QVERIFY(f->stale());
        QCOMPARE(f->source(), QStringLiteral("poe_ninja"));
        QCOMPARE(f->divineChaos().value(), 200.0);
        QCOMPARE(f->fetchedAt(), QDateTime(QDate(2026, 11, 19), QTime(21, 0), QTimeZone::UTC));
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 3);
        // A fresh push clears the stale flag.
        rig.fake.push("rates.update", sampleRates("Covens", false));
        QTRY_VERIFY_WITH_TIMEOUT(!rig.dash.rates()->stale(), 5000);
        QCOMPARE(rig.dash.rates()->updates(), 2);
    }

    void subscribeError_showsMessage()
    {
        Rig rig;
        QVERIFY(rig.connect());
        rig.fake.replyError(rig.last("rates.subscribe"), "upstream_unavailable",
                            "poe.ninja can't be reached and there are no saved rates yet.");
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Error, 5000);
        QCOMPARE(rig.dash.rates()->errorCode(), QStringLiteral("upstream_unavailable"));
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Covens"));
        QVERIFY(rig.dash.rates()->message().contains("poe.ninja can't be reached"));
        // The subscription stays active: a later push fills the table.
        rig.fake.push("rates.update", sampleRates("Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Ready, 5000);
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 3);
    }

    void ratesErrorPush_clearsTable_thenUpdateReplaces()
    {
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        QVERIFY(lc->select("Ruthless Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        rig.fake.reply(rig.last("league.set"), "league.changed", QJsonObject{{"league", "Ruthless Covens"}});
        rig.fake.send("error", QJsonValue::Null, ratesErrorPush("Ruthless Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Error, 5000);
        QCOMPARE(rig.dash.rates()->league(), QStringLiteral("Ruthless Covens"));
        QCOMPARE(rig.dash.rates()->message(), QStringLiteral("poe.ninja has no prices for this league."));
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 0);
        QCOMPARE(lc->current(), QStringLiteral("Ruthless Covens")); // the change itself succeeded

        rig.fake.push("rates.update", sampleRates("Ruthless Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Ready, 5000);
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 3);
    }

    void ratesErrorPush_whileShowingData()
    {
        // The error push may also arrive without a league change of ours.
        Rig rig;
        QVERIFY(rig.connectLoaded());
        rig.fake.send("error", QJsonValue::Null, ratesErrorPush("Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Error, 5000);
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 0);
    }

    void otherErrorPush_ignored()
    {
        Rig rig;
        QVERIFY(rig.connectLoaded());
        rig.fake.send("error", QJsonValue::Null, QJsonObject{{"code", "bad_json"}, {"message", "x"}});
        rig.fake.send("error", QJsonValue::Null,
                      QJsonObject{{"code", "upstream_unavailable"}, {"message", "x"}, {"topic", "price"}});
        QTest::qWait(150);
        QCOMPARE(rig.dash.rates()->state(), RS::Ready);
        QCOMPARE(rig.dash.rates()->model()->rowCount(), 3);
    }

    void disconnect_keepsRows_reconnect_resubscribes()
    {
        Rig rig;
        QVERIFY(rig.connectLoaded());
        QSignalSpy closed(&rig.client, &ProtocolClient::closed);
        rig.fake.dropConnection();
        QVERIFY(closed.wait(5000));
        RatesFeed *f = rig.dash.rates();
        // NFR-REL-3: last data stays, marked as not live.
        QCOMPARE(f->state(), RS::Ready);
        QVERIFY(!f->live());
        QCOMPARE(f->model()->rowCount(), 3);
        QVERIFY(!rig.dash.leagues()->connected());
        QVERIFY(!rig.dash.health()->live());
        QVERIFY(!rig.dash.leagues()->select("Standard"));

        // BackendConnection would reconnect; here the test does.
        QVERIFY(rig.connect());
        QCOMPARE(rig.fake.connections, 2);
        QCOMPARE(rig.fake.countOf("rates.subscribe"), 2);
        QCOMPARE(rig.fake.countOf("leagues.list"), 2);
        QVERIFY(f->live());
        QCOMPARE(f->state(), RS::Ready); // old rows until the reply
        QTRY_VERIFY_WITH_TIMEOUT(rig.dash.health()->live(), 5000);
        rig.fake.reply(rig.last("rates.subscribe"), "rates.update", sampleRates("Covens", true));
        QTRY_VERIFY_WITH_TIMEOUT(f->stale(), 5000);
    }

    void disconnect_whileChanging_reportsFailure()
    {
        Rig rig;
        QVERIFY(rig.connectLoaded());
        LeagueController *lc = rig.dash.leagues();
        QSignalSpy failed(lc, &LeagueController::changeFailed);
        QVERIFY(lc->select("Standard"));
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        rig.fake.dropConnection();
        QVERIFY(failed.wait(5000));
        QCOMPARE(failed.size(), 1);
        QCOMPARE(failed.first().at(1).toString(), QStringLiteral("disconnected"));
        QCOMPARE(lc->current(), QStringLiteral("Covens"));
        QVERIFY(!lc->isPending());
    }

    void silentClose_viaConnectionLost()
    {
        // ProtocolClient::close() (user Restart) emits nothing; the window
        // calls Dashboard::connectionLost() from the status change instead.
        Rig rig;
        QVERIFY(rig.connectLoaded());
        rig.client.close();
        rig.dash.connectionLost();
        rig.dash.connectionLost(); // idempotent
        QVERIFY(!rig.dash.rates()->live());
        QVERIFY(!rig.dash.leagues()->connected());
    }

    void health_reportInOrder()
    {
        Rig rig;
        rig.fake.healthPayload = QJsonObject{
            {"uptime_s", 125},
            {"sources",
             QJsonArray{QJsonObject{{"name", "trade_leagues"}, {"status", "degraded"},
                                    {"last_success", "2026-11-19T21:00:00.000Z"}, {"cache_age_s", 245},
                                    {"detail", "HTTP 503"}, {"rate_limit", QJsonValue::Null}},
                        QJsonObject{{"name", "poe_ninja"}, {"status", "ok"}, {"last_success", QJsonValue::Null},
                                    {"cache_age_s", QJsonValue::Null}, {"detail", QJsonValue::Null},
                                    {"rate_limit", QJsonValue::Null}},
                        QJsonObject{{"name", "trade_api"}, {"status", "idle"},
                                    {"rate_limit", QJsonObject{{"policy", "trade-search-request-limit"},
                                                               {"queued", 2},
                                                               {"restricted_until", QJsonValue::Null}}}}}}};
        QVERIFY(rig.connect());
        HealthModel *h = rig.dash.health();
        QTRY_VERIFY_WITH_TIMEOUT(h->hasReport(), 5000);
        QVERIFY(h->live());
        QCOMPARE(h->rowCount(), 3);
        QCOMPARE(h->uptimeS(), 125);
        // In the order given.
        QCOMPARE(h->sources().at(0).name, QStringLiteral("trade_leagues"));
        QCOMPARE(h->sources().at(2).name, QStringLiteral("trade_api"));
        QCOMPARE(h->index(0, HealthModel::Status).data(HealthModel::StatusRole).toString(), QStringLiteral("degraded"));
        QCOMPARE(h->index(0, HealthModel::CacheAge).data().toString(), QStringLiteral("4 min"));
        QCOMPARE(h->index(0, HealthModel::Detail).data().toString(), QStringLiteral("HTTP 503"));
        QCOMPARE(h->index(1, HealthModel::LastSuccess).data().toString(), QStringLiteral("never"));
        QCOMPARE(h->index(1, HealthModel::RateLimit).data().toString(), QStringLiteral("–"));
        QCOMPARE(h->index(2, HealthModel::RateLimit).data().toString(),
                 QStringLiteral("trade-search-request-limit · 2 queued"));
        QCOMPARE(h->summary(), QStringLiteral("3 sources: 1 ok, 1 degraded, 1 idle"));

        QSignalSpy closed(&rig.client, &ProtocolClient::closed);
        rig.fake.dropConnection();
        QVERIFY(closed.wait(5000));
        QVERIFY(!h->live());
        QCOMPARE(h->rowCount(), 3); // last report kept
        QCOMPARE(h->index(0, HealthModel::Status).data(HealthModel::StatusRole).toString(), QStringLiteral("unknown"));
    }

    void health_rateLimitCoolingDown()
    {
        HealthModel h;
        const QDateTime now(QDate(2026, 11, 19), QTime(21, 0), QTimeZone::UTC);
        h.setReport(QJsonObject{{"uptime_s", 1},
                                {"sources", QJsonArray{QJsonObject{
                                                {"name", "trade_api"},
                                                {"status", "degraded"},
                                                {"rate_limit", QJsonObject{{"policy", "p"},
                                                                           {"queued", 0},
                                                                           {"restricted_until",
                                                                            "2026-11-19T21:01:29.000Z"}}}}}}},
                    now);
        QCOMPARE(h.index(0, HealthModel::RateLimit).data().toString(),
                 QStringLiteral("p · nothing queued · cooling down for 1 min"));
        QCOMPARE(h.index(0, HealthModel::LastSuccess).data().toString(), QStringLiteral("never"));
    }
};

QTEST_GUILESS_MAIN(TestDashboardClient)
#include "tst_dashboard_client.moc"
