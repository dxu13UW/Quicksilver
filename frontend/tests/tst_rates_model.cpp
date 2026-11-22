// RatesModel, RatesSortProxy and the rates.update parser.
// Requirements: DASH-1 (rates table in chaos and divine, numeric sorting,
// updates keep the user's view), NFR-REL-3 (stale flag carried through),
// NFR-MNT-2 (rates.update payload per PROTOCOL).

#include "core/rates_model.h"
#include "fake_backend.h"

#include <QAbstractItemModelTester>
#include <QSignalSpy>
#include <QTest>

using namespace qs;
using namespace qs::test;

namespace {
RatesSnapshot snap(const QJsonObject &payload)
{
    auto s = parseRatesUpdate(payload);
    if (!s)
        qFatal("bad payload");
    return *s;
}

QStringList proxyIds(const QSortFilterProxyModel &p)
{
    QStringList ids;
    for (int r = 0; r < p.rowCount(); ++r)
        ids << p.index(r, 0).data(RatesModel::IdRole).toString();
    return ids;
}

// Many rows with distinct, predictable values.
QJsonObject bigUpdate(const QString &league, double factor, int n = 40)
{
    QJsonArray rows;
    for (int i = 0; i < n; ++i) {
        const double chaos = (n - i) * 10.0 * factor;
        rows.append(rateRow(QStringLiteral("c%1").arg(i), QStringLiteral("Currency %1").arg(i, 2, 10, QLatin1Char('0')),
                            chaos, 200, i % 7 == 0 ? QJsonValue(QJsonValue::Null) : QJsonValue(double(i % 5) - 2.0),
                            double(i * 100)));
    }
    return ratesUpdate(league, rows);
}
} // namespace

class TestRatesModel : public QObject {
    Q_OBJECT
private slots:
    void parse_fullPayload()
    {
        const auto s = parseRatesUpdate(sampleRates("Covens", true));
        QVERIFY(s);
        QCOMPARE(s->league, QStringLiteral("Covens"));
        QCOMPARE(s->source, QStringLiteral("poe_ninja"));
        QVERIFY(s->stale);
        QCOMPARE(s->divineChaos.value(), 200.0);
        QCOMPARE(s->fetchedAt, QDateTime(QDate(2026, 11, 19), QTime(21, 0), QTimeZone::UTC));
        QCOMPARE(s->rows.size(), 3);
        QCOMPARE(s->rows[0].name, QStringLiteral("Divine Orb"));
        QCOMPARE(s->rows[0].divine.value(), 1.0);
        QCOMPARE(s->rows[0].change7d.value(), -2.1);
        QVERIFY(!s->rows[2].change7d); // null
        QCOMPARE(s->rows[2].volumeChaos.value(), 800.0);
    }

    void parse_rejectsMalformed()
    {
        QVERIFY(!parseRatesUpdate({}));
        QVERIFY(!parseRatesUpdate(QJsonObject{{"league", "X"}}));
        QVERIFY(!parseRatesUpdate(QJsonObject{{"league", 3}, {"rates", QJsonArray{}}}));
        // Rows without an id are skipped; unknown fields ignored.
        const auto s = parseRatesUpdate(QJsonObject{
            {"league", "X"}, {"extra", true},
            {"rates", QJsonArray{QJsonObject{{"name", "no id"}}, QJsonObject{{"id", "a"}, {"chaos", 1}}}}});
        QVERIFY(s);
        QCOMPARE(s->rows.size(), 1);
        QCOMPARE(s->rows[0].name, QStringLiteral("a")); // name falls back to id
        QVERIFY(!s->stale);
        QVERIFY(!s->fetchedAt.isValid());
    }

    void model_displayAndRoles()
    {
        RatesModel m;
        QAbstractItemModelTester tester(&m, QAbstractItemModelTester::FailureReportingMode::QtTest);
        m.setSnapshot(snap(sampleRates("Covens")));
        QCOMPARE(m.rowCount(), 3);
        QCOMPARE(m.columnCount(), 5);
        QCOMPARE(m.league(), QStringLiteral("Covens"));
        QCOMPARE(m.headerData(RatesModel::Change7d, Qt::Horizontal).toString(), QStringLiteral("7-day change"));
        QCOMPARE(m.index(1, RatesModel::Chaos).data().toString(), QStringLiteral("15.0"));
        QCOMPARE(m.index(1, RatesModel::Divine).data().toString(), QStringLiteral("0.075"));
        QCOMPARE(m.index(1, RatesModel::Change7d).data().toString(), QStringLiteral("+3.5%"));
        QCOMPARE(m.index(2, RatesModel::Change7d).data().toString(), QStringLiteral("–"));
        QVERIFY(!m.index(2, RatesModel::Change7d).data(RatesModel::SortRole).isValid());
        QCOMPARE(m.index(1, RatesModel::Chaos).data(RatesModel::SortRole).toDouble(), 15.0);
        QCOMPARE(m.index(0, RatesModel::Name).data(RatesModel::IdRole).toString(), QStringLiteral("divine"));
    }

    void update_sameLeague_isInPlace()
    {
        RatesModel m;
        QAbstractItemModelTester tester(&m, QAbstractItemModelTester::FailureReportingMode::QtTest);
        m.setSnapshot(snap(sampleRates("Covens")));
        QPersistentModelIndex exalted(m.index(m.rowOf("exalted"), RatesModel::Chaos));

        QSignalSpy reset(&m, &QAbstractItemModel::modelReset);
        QSignalSpy changed(&m, &QAbstractItemModel::dataChanged);
        QSignalSpy removed(&m, &QAbstractItemModel::rowsRemoved);
        QSignalSpy inserted(&m, &QAbstractItemModel::rowsInserted);

        // exalted price changes, alch disappears, chaos appears.
        m.setSnapshot(snap(ratesUpdate("Covens", QJsonArray{rateRow("divine", "Divine Orb", 210, 210),
                                                             rateRow("exalted", "Exalted Orb", 17, 210),
                                                             rateRow("chaos", "Chaos Orb", 1, 210)})));
        QCOMPARE(reset.size(), 0);
        QCOMPARE(changed.size(), 1);
        QCOMPARE(removed.size(), 1);
        QCOMPARE(inserted.size(), 1);
        QCOMPARE(m.rowCount(), 3);
        QVERIFY(exalted.isValid());
        QCOMPARE(exalted.data(RatesModel::SortRole).toDouble(), 17.0);
        QCOMPARE(m.rowOf("alch"), -1);
        QVERIFY(m.rowOf("chaos") >= 0);
    }

    void update_otherLeague_resets()
    {
        RatesModel m;
        m.setSnapshot(snap(sampleRates("Covens")));
        QSignalSpy reset(&m, &QAbstractItemModel::modelReset);
        m.setSnapshot(snap(sampleRates("Standard")));
        QCOMPARE(reset.size(), 1);
        QCOMPARE(m.league(), QStringLiteral("Standard"));
        m.clear();
        QCOMPARE(m.rowCount(), 0);
        QCOMPARE(m.league(), QString());
    }

    void proxy_sortsNumerically()
    {
        RatesModel m;
        RatesSortProxy p;
        p.setSourceModel(&m);
        // 200 vs 15 vs 0.5: a text sort would put "15" before "200" ascending
        // and "0.50" first; check the order is by value.
        m.setSnapshot(snap(sampleRates("Covens")));
        p.sort(RatesModel::Chaos, Qt::AscendingOrder);
        QCOMPARE(proxyIds(p), (QStringList{"alch", "exalted", "divine"}));
        p.sort(RatesModel::Chaos, Qt::DescendingOrder);
        QCOMPARE(proxyIds(p), (QStringList{"divine", "exalted", "alch"}));
        p.sort(RatesModel::Volume, Qt::AscendingOrder);
        QCOMPARE(proxyIds(p), (QStringList{"alch", "exalted", "divine"}));
        p.sort(RatesModel::Name, Qt::AscendingOrder);
        QCOMPARE(proxyIds(p), (QStringList{"divine", "exalted", "alch"}));
    }

    void proxy_nullsLastInBothOrders()
    {
        RatesModel m;
        RatesSortProxy p;
        p.setSourceModel(&m);
        m.setSnapshot(snap(sampleRates("Covens"))); // alch has change_7d null
        p.sort(RatesModel::Change7d, Qt::AscendingOrder);
        QCOMPARE(proxyIds(p), (QStringList{"divine", "exalted", "alch"}));
        p.sort(RatesModel::Change7d, Qt::DescendingOrder);
        QCOMPARE(proxyIds(p), (QStringList{"exalted", "divine", "alch"}));
    }

    void proxy_tiesKeepBackendOrder()
    {
        RatesModel m;
        RatesSortProxy p;
        p.setSourceModel(&m);
        m.setSnapshot(snap(ratesUpdate("L", QJsonArray{rateRow("a", "A", 5, 100), rateRow("b", "B", 5, 100),
                                                       rateRow("c", "C", 5, 100)})));
        p.sort(RatesModel::Chaos, Qt::DescendingOrder);
        QCOMPARE(proxyIds(p), (QStringList{"a", "b", "c"}));
        p.sort(RatesModel::Chaos, Qt::AscendingOrder);
        QCOMPARE(proxyIds(p), (QStringList{"a", "b", "c"}));
    }

    void proxy_sortSurvivesUpdates()
    {
        // The user sorted by name; a refresh with new prices (and a new and a
        // removed row) keeps that sort and the order stays consistent.
        RatesModel m;
        RatesSortProxy p;
        p.setSourceModel(&m);
        m.setSnapshot(snap(bigUpdate("L", 1.0)));
        p.sort(RatesModel::Name, Qt::DescendingOrder);
        const QStringList before = proxyIds(p);
        m.setSnapshot(snap(bigUpdate("L", 1.37)));
        QCOMPARE(p.sortColumn(), int(RatesModel::Name));
        QCOMPARE(p.sortOrder(), Qt::DescendingOrder);
        QCOMPARE(proxyIds(p), before);

        // Sorted by chaos ascending, prices reverse: the proxy re-sorts.
        p.sort(RatesModel::Chaos, Qt::AscendingOrder);
        QJsonArray rows;
        for (int i = 0; i < 40; ++i)
            rows.append(rateRow(QStringLiteral("c%1").arg(i), QStringLiteral("x"), (i + 1) * 3.0, 200));
        m.setSnapshot(snap(ratesUpdate("L", rows)));
        QCOMPARE(p.sortColumn(), int(RatesModel::Chaos));
        const QStringList ids = proxyIds(p);
        QCOMPARE(ids.first(), QStringLiteral("c0"));
        QCOMPARE(ids.last(), QStringLiteral("c39"));
        for (int r = 1; r < p.rowCount(); ++r)
            QVERIFY(p.index(r - 1, RatesModel::Chaos).data(RatesModel::SortRole).toDouble() <=
                    p.index(r, RatesModel::Chaos).data(RatesModel::SortRole).toDouble());
    }

    void proxy_filterByName()
    {
        RatesModel m;
        RatesSortProxy p;
        p.setSourceModel(&m);
        m.setSnapshot(snap(sampleRates("Covens")));
        p.setFilterFixedString("orb of");
        QCOMPARE(proxyIds(p), QStringList{"alch"});
    }
};

QTEST_GUILESS_MAIN(TestRatesModel)
#include "tst_rates_model.moc"
