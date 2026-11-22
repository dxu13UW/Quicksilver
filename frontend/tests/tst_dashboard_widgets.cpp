// Dashboard widgets against a fake backend (offscreen platform).
// Requirements: DASH-2 (only a user choice sends league.set; pending state;
// revert on error), DASH-1 (table vs empty/loading/error states; refreshes
// keep sort and scroll), NFR-REL-3 (STALE marker), DASH-3 (health panel),
// NFR-UX-3 (plain-language messages).

#include "core/backend_connection.h"
#include "core/dashboard.h"
#include "core/protocol_client.h"
#include "fake_backend.h"
#include "ui/command_center_window.h"
#include "ui/health_panel.h"
#include "ui/league_selector.h"
#include "ui/rates_panel.h"

#include <QComboBox>
#include <QHeaderView>
#include <QScrollBar>
#include <QSignalSpy>
#include <QTabWidget>
#include <QTableView>
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
    QJsonObject last(const QString &type) const { return fake.requestsOf(type).last(); }
    bool connect()
    {
        client.open(fake.port(), QStringLiteral("t"));
        return QTest::qWaitFor([&] { return fake.countOf("rates.subscribe") > 0; }, 5000);
    }
    bool connectLoaded(const QJsonObject &rates = sampleRates("Covens"))
    {
        if (!connect())
            return false;
        fake.reply(last("leagues.list"), "leagues.result",
                   leaguesResult({"Covens", "Standard", "Ruthless Covens"}, "Covens"));
        fake.reply(last("rates.subscribe"), "rates.update", rates);
        return QTest::qWaitFor([&] {
            return dash.leagues()->listState() == LS::Loaded && dash.rates()->state() == RS::Ready;
        }, 5000);
    }
};

QJsonObject manyRates(const QString &league, double factor, int n = 60)
{
    QJsonArray rows;
    for (int i = 0; i < n; ++i)
        rows.append(rateRow(QStringLiteral("c%1").arg(i), QStringLiteral("Currency %1").arg(i, 2, 10, QLatin1Char('0')),
                            (n - i) * 10.0 * factor, 200, double(i % 5) - 2.0, double(i * 100)));
    return ratesUpdate(league, rows);
}
} // namespace

class TestDashboardWidgets : public QObject {
    Q_OBJECT
private slots:
    void leagueSelector_fillFromCode_sendsNothing()
    {
        Rig rig;
        LeagueSelector sel(rig.dash.leagues());
        sel.show();
        QVERIFY(!sel.combo()->isEnabled()); // not connected
        QVERIFY(rig.connectLoaded());
        QComboBox *combo = sel.combo();
        QCOMPARE(combo->count(), 3);
        QCOMPARE(combo->currentText(), QStringLiteral("Covens"));
        QVERIFY(combo->isEnabled());
        // Programmatic changes (and further fills) never send league.set.
        combo->setCurrentIndex(1);
        rig.dash.leagues()->reload();
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("leagues.list"), 2, 5000);
        rig.fake.reply(rig.last("leagues.list"), "leagues.result",
                       leaguesResult({"Covens", "Standard", "Ruthless Covens", "Hardcore Covens"}, "Covens"));
        QTRY_COMPARE_WITH_TIMEOUT(combo->count(), 4, 5000);
        QCOMPARE(combo->currentText(), QStringLiteral("Covens"));
        QTest::qWait(100);
        QCOMPARE(rig.fake.countOf("league.set"), 0);
    }

    void leagueSelector_beforeList_showsWelcomeLeague()
    {
        Rig rig;
        LeagueSelector sel(rig.dash.leagues());
        QVERIFY(rig.connect());
        QCOMPARE(sel.combo()->currentText(), QStringLiteral("Covens"));
        QVERIFY(!sel.combo()->isEnabled());
        QCOMPARE(sel.noteText(), QStringLiteral("Loading leagues…"));
        rig.fake.replyError(rig.last("leagues.list"), "upstream_unavailable", "The league list can't be fetched right now.");
        QTRY_VERIFY_WITH_TIMEOUT(sel.noteText().startsWith("League list unavailable"), 5000);
        QCOMPARE(sel.combo()->currentText(), QStringLiteral("Covens"));
        QVERIFY(!sel.combo()->isEnabled());
    }

    void leagueSelector_userChoice_sendsLeagueSet_success()
    {
        Rig rig;
        LeagueSelector sel(rig.dash.leagues());
        sel.show();
        QVERIFY(QTest::qWaitForWindowExposed(&sel));
        QVERIFY(rig.connectLoaded());
        QComboBox *combo = sel.combo();
        combo->setFocus();
        QTest::keyClick(combo, Qt::Key_Down); // user picks the next league
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        QCOMPARE(rig.last("league.set").value("payload").toObject().value("league").toString(),
                 QStringLiteral("Standard"));
        // Pending: shows the choice and says so; the combo keeps focus.
        QCOMPARE(combo->currentText(), QStringLiteral("Standard"));
        QCOMPARE(sel.noteText(), QStringLiteral("Switching to Standard…"));
        QVERIFY(combo->hasFocus());
        // Another choice while pending is refused and the combo snaps back.
        QTest::keyClick(combo, Qt::Key_Down);
        QCOMPARE(combo->currentText(), QStringLiteral("Standard"));
        QTest::qWait(100);
        QCOMPARE(rig.fake.countOf("league.set"), 1);

        rig.fake.reply(rig.last("league.set"), "league.changed", QJsonObject{{"league", "Standard"}});
        QTRY_VERIFY_WITH_TIMEOUT(sel.noteText().startsWith("Switched to Standard."), 5000);
        QVERIFY(combo->isEnabled());
        QCOMPARE(combo->currentText(), QStringLiteral("Standard"));
        QCOMPARE(rig.fake.countOf("league.set"), 1);
    }

    void leagueSelector_error_revertsCombo()
    {
        Rig rig;
        LeagueSelector sel(rig.dash.leagues());
        sel.show();
        QVERIFY(QTest::qWaitForWindowExposed(&sel));
        QVERIFY(rig.connectLoaded());
        QComboBox *combo = sel.combo();
        combo->setFocus();
        QTest::keyClick(combo, Qt::Key_End); // last item
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        QCOMPARE(combo->currentText(), QStringLiteral("Ruthless Covens"));
        rig.fake.replyError(rig.last("league.set"), "unknown_league", "League 'Ruthless Covens' isn't available.");
        QTRY_COMPARE_WITH_TIMEOUT(combo->currentText(), QStringLiteral("Covens"), 5000);
        QVERIFY(combo->isEnabled());
        QCOMPARE(sel.noteText(),
                 QStringLiteral("Couldn't switch to Ruthless Covens: League 'Ruthless Covens' isn't available."));
        QCOMPARE(rig.fake.countOf("league.set"), 1);
    }

    void leagueSelector_backendPush_updatesComboWithoutSending()
    {
        Rig rig;
        LeagueSelector sel(rig.dash.leagues());
        sel.show();
        QVERIFY(rig.connectLoaded());
        rig.fake.push("league.changed", QJsonObject{{"league", "Standard"}});
        QTRY_COMPARE_WITH_TIMEOUT(sel.combo()->currentText(), QStringLiteral("Standard"), 5000);
        QCOMPARE(sel.noteText(), QStringLiteral("Backend switched to Standard"));
        QVERIFY(sel.combo()->isEnabled());
        QTest::qWait(150);
        QCOMPARE(rig.fake.countOf("league.set"), 0);
    }

    void leagueSelector_pushDuringPending_keepsChoiceShown()
    {
        Rig rig;
        LeagueSelector sel(rig.dash.leagues());
        sel.show();
        QVERIFY(QTest::qWaitForWindowExposed(&sel));
        QVERIFY(rig.connectLoaded());
        sel.combo()->setFocus();
        QTest::keyClick(sel.combo(), Qt::Key_End); // Ruthless Covens
        QTRY_COMPARE_WITH_TIMEOUT(rig.fake.countOf("league.set"), 1, 5000);
        rig.fake.push("league.changed", QJsonObject{{"league", "Standard"}});
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.leagues()->current(), QStringLiteral("Standard"), 5000);
        QCOMPARE(sel.combo()->currentText(), QStringLiteral("Ruthless Covens"));
        QCOMPARE(sel.noteText(), QStringLiteral("Switching to Ruthless Covens…"));
    }

    void ratesPanel_states()
    {
        Rig rig;
        RatesPanel panel(rig.dash.rates());
        QVERIFY(!panel.showingTable());
        QVERIFY(panel.messageText().startsWith("Waiting for the backend"));

        QVERIFY(rig.connect());
        QVERIFY(panel.messageText().startsWith("Loading rates for Covens"));

        rig.fake.reply(rig.last("rates.subscribe"), "rates.update", sampleRates("Covens", true));
        QTRY_VERIFY_WITH_TIMEOUT(panel.showingTable(), 5000);
        QCOMPARE(panel.headingText(), QStringLiteral("Currency rates · Covens"));
        QVERIFY(panel.staleMarkerVisible());
        QVERIFY2(panel.metaText().contains("poe.ninja · updated "), qPrintable(panel.metaText()));
        QVERIFY(panel.metaText().contains("ago"));
        QVERIFY(panel.metaText().contains("1 divine = 200 chaos"));
        QVERIFY(panel.metaText().contains("cached data"));
        QCOMPARE(panel.table()->model()->rowCount(), 3);

        rig.fake.push("rates.update", sampleRates("Covens", false));
        QTRY_VERIFY_WITH_TIMEOUT(!panel.staleMarkerVisible(), 5000);

        rig.fake.send("error", QJsonValue::Null, ratesErrorPush("Ruthless Covens"));
        QTRY_VERIFY_WITH_TIMEOUT(!panel.showingTable(), 5000);
        QVERIFY(panel.messageText().startsWith("No rates for Ruthless Covens\npoe.ninja has no prices for this league."));
        QCOMPARE(panel.headingText(), QStringLiteral("Currency rates · Ruthless Covens"));
        QVERIFY(!panel.staleMarkerVisible());
        QCOMPARE(panel.table()->model()->rowCount(), 0);
    }

    void ratesPanel_emptyList()
    {
        Rig rig;
        RatesPanel panel(rig.dash.rates());
        QVERIFY(rig.connect());
        rig.fake.reply(rig.last("rates.subscribe"), "rates.update", ratesUpdate("Covens", QJsonArray{}));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->state(), RS::Ready, 5000);
        QVERIFY(!panel.showingTable());
        QVERIFY(panel.messageText().startsWith("No rates in this update"));
    }

    void ratesPanel_refreshKeepsSortAndScroll()
    {
        Rig rig;
        RatesPanel panel(rig.dash.rates());
        panel.resize(600, 300);
        panel.show();
        QVERIFY(QTest::qWaitForWindowExposed(&panel));
        QVERIFY(rig.connectLoaded(manyRates("Covens", 1.0)));
        QTableView *t = panel.table();
        QTRY_VERIFY_WITH_TIMEOUT(t->verticalScrollBar()->maximum() > 10, 5000);

        // The user sorts by name, descending, and scrolls down.
        t->sortByColumn(RatesModel::Name, Qt::DescendingOrder);
        t->verticalScrollBar()->setValue(20);
        const int scroll = t->verticalScrollBar()->value();
        QVERIFY(scroll > 0);
        const QString topName = t->model()->index(t->rowAt(0), RatesModel::Name).data().toString();

        // A refresh with new prices.
        const int before = rig.dash.rates()->updates();
        rig.fake.push("rates.update", manyRates("Covens", 1.2));
        QTRY_COMPARE_WITH_TIMEOUT(rig.dash.rates()->updates(), before + 1, 5000);
        QCoreApplication::processEvents();

        QCOMPARE(t->horizontalHeader()->sortIndicatorSection(), int(RatesModel::Name));
        QCOMPARE(t->horizontalHeader()->sortIndicatorOrder(), Qt::DescendingOrder);
        QCOMPARE(t->verticalScrollBar()->value(), scroll);
        QCOMPARE(t->model()->index(t->rowAt(0), RatesModel::Name).data().toString(), topName);
        // Prices did change.
        QCOMPARE(t->model()->index(0, RatesModel::Name).data().toString(), QStringLiteral("Currency 59"));
        QCOMPARE(t->model()->index(0, RatesModel::Chaos).data(RatesModel::SortRole).toDouble(), 12.0);
    }

    void ratesPanel_defaultSortIsChaosDescending()
    {
        Rig rig;
        RatesPanel panel(rig.dash.rates());
        QVERIFY(rig.connectLoaded());
        QTableView *t = panel.table();
        QCOMPARE(t->horizontalHeader()->sortIndicatorSection(), int(RatesModel::Chaos));
        QCOMPARE(t->horizontalHeader()->sortIndicatorOrder(), Qt::DescendingOrder);
        QCOMPARE(t->model()->index(0, RatesModel::Name).data().toString(), QStringLiteral("Divine Orb"));
    }

    void healthPanel_rendersBadges()
    {
        Rig rig;
        rig.fake.healthPayload = QJsonObject{
            {"uptime_s", 300},
            {"sources", QJsonArray{QJsonObject{{"name", "poe_ninja"}, {"status", "ok"}},
                                   QJsonObject{{"name", "trade_leagues"}, {"status", "down"},
                                               {"detail", "no route to host"}}}}};
        HealthPanel panel(rig.dash.health());
        panel.resize(700, 200);
        panel.show();
        QCOMPARE(panel.summaryText(), QStringLiteral("waiting for the first report"));
        QVERIFY(rig.connect());
        QTRY_VERIFY_WITH_TIMEOUT(rig.dash.health()->hasReport(), 5000);
        QCOMPARE(panel.summaryText(), QStringLiteral("2 sources: 1 ok, 1 down · backend up 5 min"));
        QCOMPARE(panel.table()->model()->index(0, HealthModel::Source).data().toString(),
                 QStringLiteral("poe.ninja prices"));
        QVERIFY(!panel.grab().isNull()); // paints the badge delegate
        QCOMPARE(StatusBadgeDelegate::colorFor("ok"), QColor(0x2f, 0x9e, 0x62));
        QVERIFY(StatusBadgeDelegate::colorFor("down") != StatusBadgeDelegate::colorFor("degraded"));

        rig.client.close();
        rig.dash.connectionLost();
        QVERIFY(panel.summaryText().startsWith("not connected; last report"));
    }

    void commandCenter_smoke()
    {
        // Not started: the dashboard shows its waiting states.
        BackendCommand cmd;
        BackendConnection conn(cmd);
        CommandCenterWindow w(&conn);
        w.show();
        QVERIFY(QTest::qWaitForWindowExposed(&w));
        auto *tabs = w.findChild<QTabWidget *>();
        QVERIFY(tabs);
        QCOMPARE(tabs->count(), 2);
        QCOMPARE(tabs->tabText(0), QStringLiteral("Dashboard"));
        QCOMPARE(tabs->tabText(1), QStringLiteral("Backend log"));
        QVERIFY(w.ratesPanel()->messageText().startsWith("Waiting for the backend"));
        QVERIFY(!w.leagueSelector()->combo()->isEnabled());
        QVERIFY(!w.grab().isNull());
    }
};

QTEST_MAIN(TestDashboardWidgets)
#include "tst_dashboard_widgets.moc"
