// Dashboard text helpers.
// Requirements: DASH-1 (prices in chaos and divine, time of last update),
// NFR-REL-3 (age of cached data), NFR-UX-3 (plain-language wording).

#include "core/dashboard_format.h"

#include <QJsonValue>
#include <QTest>

using namespace qs;

class TestDashboardFormat : public QObject {
    Q_OBJECT
private slots:
    void parseTimestamp_protocolFormat()
    {
        const QDateTime t = fmt::parseTimestamp(QJsonValue("2026-11-19T21:04:05.123Z"));
        QVERIFY(t.isValid());
        QCOMPARE(t.timeSpec(), Qt::UTC);
        QCOMPARE(t, QDateTime(QDate(2026, 11, 19), QTime(21, 4, 5, 123), QTimeZone::UTC));
        QVERIFY(!fmt::parseTimestamp(QJsonValue()).isValid());
        QVERIFY(!fmt::parseTimestamp(QJsonValue("yesterday")).isValid());
        QVERIFY(!fmt::parseTimestamp(QJsonValue(12)).isValid());
    }

    void optionalNumber()
    {
        QCOMPARE(fmt::optionalNumber(QJsonValue(1.5)).value(), 1.5);
        QVERIFY(!fmt::optionalNumber(QJsonValue(QJsonValue::Null)));
        QVERIFY(!fmt::optionalNumber(QJsonValue()));
        QVERIFY(!fmt::optionalNumber(QJsonValue("3")));
    }

    void ago_data()
    {
        QTest::addColumn<qint64>("s");
        QTest::addColumn<QString>("text");
        QTest::newRow("skew") << qint64(-30) << "just now";
        QTest::newRow("0") << qint64(0) << "just now";
        QTest::newRow("44") << qint64(44) << "just now";
        QTest::newRow("60") << qint64(60) << "1 min ago";
        QTest::newRow("4m") << qint64(245) << "4 min ago";
        QTest::newRow("59m") << qint64(59 * 60 + 59) << "59 min ago";
        QTest::newRow("1h") << qint64(3600) << "1 h ago";
        QTest::newRow("2h5m") << qint64(2 * 3600 + 5 * 60) << "2 h 5 min ago";
        QTest::newRow("1d") << qint64(86400 + 10) << "1 day ago";
        QTest::newRow("3d") << qint64(3 * 86400) << "3 days ago";
    }
    void ago()
    {
        QFETCH(qint64, s);
        QFETCH(QString, text);
        QCOMPARE(fmt::ago(s), text);
    }

    void duration()
    {
        QCOMPARE(fmt::duration(45), QStringLiteral("45 s"));
        QCOMPARE(fmt::duration(245), QStringLiteral("4 min"));
        QCOMPARE(fmt::duration(7200), QStringLiteral("2 h"));
    }

    void chaos_data()
    {
        QTest::addColumn<double>("v");
        QTest::addColumn<QString>("text");
        QTest::newRow("small") << 0.4567 << "0.46";
        QTest::newRow("tens") << 15.25 << "15.3";
        QTest::newRow("hundreds") << 216.2 << "216";
        QTest::newRow("thousands") << 123456.7 << "123,457";
    }
    void chaos()
    {
        QFETCH(double, v);
        QFETCH(QString, text);
        QCOMPARE(fmt::chaos(v), text);
    }

    void divine_data()
    {
        QTest::addColumn<double>("v");
        QTest::addColumn<QString>("text");
        QTest::newRow("one") << 1.0 << "1";
        QTest::newRow("fraction") << 0.07 << "0.07";
        QTest::newRow("cheap") << 0.0046253 << "0.004625";
        QTest::newRow("several") << 12.3456 << "12.35";
        QTest::newRow("big") << 1234.5 << "1,235";
        QTest::newRow("zero") << 0.0 << "0";
    }
    void divine()
    {
        QFETCH(double, v);
        QFETCH(QString, text);
        QCOMPARE(fmt::divine(v), text);
    }

    void percentAndVolume()
    {
        QCOMPARE(fmt::percentChange(2.14), QStringLiteral("+2.1%"));
        QCOMPARE(fmt::percentChange(-0.44), QStringLiteral("−0.4%"));
        QCOMPARE(fmt::percentChange(0.01), QStringLiteral("0.0%"));
        QCOMPARE(fmt::percentChange(std::nullopt), QStringLiteral("–"));
        QCOMPARE(fmt::volume(950), QStringLiteral("950 c"));
        QCOMPARE(fmt::volume(5000), QStringLiteral("5.00k c"));
        QCOMPARE(fmt::volume(120345.6), QStringLiteral("120.3k c"));
        QCOMPARE(fmt::volume(4560000), QStringLiteral("4.56M c"));
        QCOMPARE(fmt::volume(std::nullopt), QStringLiteral("–"));
        QCOMPARE(fmt::chaos(std::nullopt), QStringLiteral("–"));
    }

    void sourceNames()
    {
        QCOMPARE(fmt::sourceName("poe_ninja"), QStringLiteral("poe.ninja prices"));
        QCOMPARE(fmt::sourceName("trade_leagues"), QStringLiteral("League list"));
        QCOMPARE(fmt::sourceName("something_new"), QStringLiteral("something_new"));
    }
};

QTEST_GUILESS_MAIN(TestDashboardFormat)
#include "tst_dashboard_format.moc"
