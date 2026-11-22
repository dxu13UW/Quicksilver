#include "core/dashboard_format.h"

#include <QLocale>

#include <cmath>

namespace qs::fmt {

namespace {
const QString kDash = QStringLiteral("–");

QString grouped(double v, int decimals)
{
    // Fixed locale so the output doesn't change with the user's settings and
    // tests stay deterministic; the separators are the familiar "," and ".".
    QLocale c(QLocale::English, QLocale::UnitedStates);
    return c.toString(v, 'f', decimals);
}
} // namespace

QDateTime parseTimestamp(const QJsonValue &value)
{
    if (!value.isString())
        return {};
    QDateTime t = QDateTime::fromString(value.toString(), Qt::ISODateWithMs);
    if (t.isValid())
        t = t.toUTC();
    return t;
}

std::optional<double> optionalNumber(const QJsonValue &value)
{
    if (!value.isDouble())
        return std::nullopt;
    const double d = value.toDouble();
    if (!std::isfinite(d))
        return std::nullopt;
    return d;
}

QString duration(qint64 s)
{
    if (s < 0)
        s = 0;
    if (s < 60)
        return QStringLiteral("%1 s").arg(s);
    const qint64 min = s / 60;
    if (min < 60)
        return QStringLiteral("%1 min").arg(min);
    const qint64 h = min / 60;
    if (h < 24) {
        const qint64 m = min % 60;
        return m == 0 ? QStringLiteral("%1 h").arg(h) : QStringLiteral("%1 h %2 min").arg(h).arg(m);
    }
    const qint64 d = h / 24;
    return d == 1 ? QStringLiteral("1 day") : QStringLiteral("%1 days").arg(d);
}

QString ago(qint64 s)
{
    if (s < 45)
        return QStringLiteral("just now");
    if (s < 120)
        return QStringLiteral("1 min ago");
    return duration(s) + QStringLiteral(" ago");
}

QString chaos(std::optional<double> v)
{
    if (!v)
        return kDash;
    const double a = std::fabs(*v);
    const int decimals = a < 10 ? 2 : (a < 100 ? 1 : 0);
    return grouped(*v, decimals);
}

QString divine(std::optional<double> v)
{
    if (!v)
        return kDash;
    const double a = std::fabs(*v);
    if (a == 0)
        return QStringLiteral("0");
    if (a >= 1000)
        return grouped(*v, 0);
    // 4 significant digits without exponent notation.
    const int intDigits = a >= 1 ? int(std::floor(std::log10(a))) + 1 : 0;
    int decimals = a >= 1 ? qMax(0, 4 - intDigits) : 3 - int(std::floor(std::log10(a)));
    decimals = qMin(decimals, 8);
    QString s = QString::number(*v, 'f', decimals);
    // Trim trailing zeros after the point ("1.000" -> "1"), but keep "0.0046".
    if (s.contains(QLatin1Char('.'))) {
        while (s.endsWith(QLatin1Char('0')))
            s.chop(1);
        if (s.endsWith(QLatin1Char('.')))
            s.chop(1);
    }
    return s;
}

QString percentChange(std::optional<double> v)
{
    if (!v)
        return kDash;
    const double r = std::round(*v * 10) / 10;
    if (r == 0)
        return QStringLiteral("0.0%");
    const QString num = QString::number(std::fabs(r), 'f', 1);
    return (r > 0 ? QStringLiteral("+") : QStringLiteral("−")) + num + QStringLiteral("%");
}

QString volume(std::optional<double> v)
{
    if (!v)
        return kDash;
    const double a = std::fabs(*v);
    if (a < 1000)
        return QString::number(*v, 'f', 0) + QStringLiteral(" c");
    if (a < 1e6)
        return QString::number(*v / 1e3, 'f', a < 1e4 ? 2 : 1) + QStringLiteral("k c");
    return QString::number(*v / 1e6, 'f', a < 1e7 ? 2 : 1) + QStringLiteral("M c");
}

QString sourceName(const QString &id)
{
    if (id == QLatin1String("poe_ninja"))
        return QStringLiteral("poe.ninja prices");
    if (id == QLatin1String("trade_leagues"))
        return QStringLiteral("League list");
    if (id == QLatin1String("trade_api"))
        return QStringLiteral("Trade search");
    if (id == QLatin1String("client_log"))
        return QStringLiteral("Game log (Client.txt)");
    return id;
}

} // namespace qs::fmt
