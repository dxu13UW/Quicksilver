#include "core/health_model.h"

#include "core/dashboard_format.h"

#include <QBrush>
#include <QColor>
#include <QJsonArray>
#include <QMap>

namespace qs {

HealthModel::HealthModel(QObject *parent) : QAbstractTableModel(parent) {}

int HealthModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_sources.size());
}

int HealthModel::columnCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : ColumnCount;
}

QString HealthModel::rateLimitText(const HealthSource &s, const QDateTime &now)
{
    if (!s.hasRateLimit)
        return {};
    QStringList parts;
    if (!s.rlPolicy.isEmpty())
        parts << s.rlPolicy;
    parts << (s.rlQueued == 0 ? QStringLiteral("nothing queued") : QStringLiteral("%1 queued").arg(s.rlQueued));
    if (s.rlRestrictedUntil.isValid() && s.rlRestrictedUntil > now)
        parts << QStringLiteral("cooling down for %1").arg(fmt::duration(now.secsTo(s.rlRestrictedUntil) + 1));
    return parts.join(QStringLiteral(" · "));
}

QVariant HealthModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_sources.size())
        return {};
    const HealthSource &s = m_sources[index.row()];
    const QString dash = QStringLiteral("–");

    if (role == StatusRole)
        return m_live ? s.status : QStringLiteral("unknown");

    if (role == Qt::DisplayRole) {
        switch (index.column()) {
        case Source: return fmt::sourceName(s.name);
        case Status: return m_live ? s.status : QStringLiteral("unknown");
        case LastSuccess:
            return s.lastSuccess.isValid() ? fmt::ago(s.lastSuccess.secsTo(m_received)) : QStringLiteral("never");
        case CacheAge: return s.cacheAgeS ? fmt::duration(*s.cacheAgeS) : dash;
        case Detail: return s.detail.isEmpty() ? dash : s.detail;
        case RateLimit: {
            const QString t = rateLimitText(s, m_received);
            return t.isEmpty() ? dash : t;
        }
        }
    }
    if (role == Qt::ToolTipRole) {
        switch (index.column()) {
        case Source: return s.name;
        case LastSuccess:
            if (s.lastSuccess.isValid())
                return s.lastSuccess.toLocalTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"));
            break;
        case Detail:
            if (!s.detail.isEmpty())
                return s.detail;
            break;
        case Status:
            if (!m_live)
                return QStringLiteral("Not connected: this is the last report received.");
            if (s.status == QLatin1String("idle"))
                return QStringLiteral("Not used yet in this run");
            if (s.status == QLatin1String("ok"))
                return QStringLiteral("The last request succeeded");
            if (s.status == QLatin1String("degraded"))
                return QStringLiteral("The last request failed; cached data is still in use (marked stale)");
            if (s.status == QLatin1String("down"))
                return QStringLiteral("Requests are failing and there is no usable cache");
            break;
        }
    }
    if (role == Qt::ForegroundRole && !m_live)
        return QBrush(QColor(0x88, 0x88, 0x88));
    return {};
}

QVariant HealthModel::headerData(int section, Qt::Orientation orientation, int role) const
{
    if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
        return {};
    switch (section) {
    case Source: return QStringLiteral("Source");
    case Status: return QStringLiteral("Status");
    case LastSuccess: return QStringLiteral("Last success");
    case CacheAge: return QStringLiteral("Cache age");
    case Detail: return QStringLiteral("Detail");
    case RateLimit: return QStringLiteral("Rate limit");
    }
    return {};
}

void HealthModel::setReport(const QJsonObject &payload, const QDateTime &now)
{
    QVector<HealthSource> next;
    for (const QJsonValue &v : payload.value(QLatin1String("sources")).toArray()) {
        const QJsonObject o = v.toObject();
        HealthSource s;
        s.name = o.value(QLatin1String("name")).toString();
        s.status = o.value(QLatin1String("status")).toString();
        s.lastSuccess = fmt::parseTimestamp(o.value(QLatin1String("last_success")));
        if (const auto age = fmt::optionalNumber(o.value(QLatin1String("cache_age_s"))))
            s.cacheAgeS = qint64(*age);
        s.detail = o.value(QLatin1String("detail")).toString();
        const QJsonValue rl = o.value(QLatin1String("rate_limit"));
        if (rl.isObject()) {
            const QJsonObject r = rl.toObject();
            s.hasRateLimit = true;
            s.rlPolicy = r.value(QLatin1String("policy")).toString();
            s.rlQueued = r.value(QLatin1String("queued")).toInt();
            s.rlRestrictedUntil = fmt::parseTimestamp(r.value(QLatin1String("restricted_until")));
        }
        next.append(s);
    }
    m_uptimeS = qint64(payload.value(QLatin1String("uptime_s")).toDouble());
    m_received = now.toUTC();
    m_live = true;

    // Same source list (the usual case every 5 s): update in place so the
    // view keeps its selection and scroll.
    bool sameNames = next.size() == m_sources.size();
    for (int i = 0; sameNames && i < next.size(); ++i)
        sameNames = next[i].name == m_sources[i].name;
    if (sameNames) {
        m_sources = next;
        if (!m_sources.isEmpty())
            emit dataChanged(index(0, 0), index(int(m_sources.size()) - 1, ColumnCount - 1));
    } else {
        beginResetModel();
        m_sources = next;
        endResetModel();
    }
    emit reportChanged();
}

void HealthModel::setLive(bool live)
{
    if (m_live == live)
        return;
    m_live = live;
    if (!m_sources.isEmpty())
        emit dataChanged(index(0, 0), index(int(m_sources.size()) - 1, ColumnCount - 1));
    emit reportChanged();
}

QString HealthModel::summary() const
{
    if (!hasReport())
        return QStringLiteral("No health report yet.");
    if (m_sources.isEmpty())
        return QStringLiteral("The backend reports no data sources.");
    // Count per status, in a fixed order.
    const QStringList order{QStringLiteral("ok"), QStringLiteral("degraded"), QStringLiteral("down"),
                            QStringLiteral("idle")};
    QMap<QString, int> counts;
    for (const HealthSource &s : m_sources)
        counts[s.status] += 1;
    QStringList parts;
    for (const QString &st : order)
        if (counts.value(st))
            parts << QStringLiteral("%1 %2").arg(counts.value(st)).arg(st);
    for (auto it = counts.cbegin(); it != counts.cend(); ++it)
        if (!order.contains(it.key()))
            parts << QStringLiteral("%1 %2").arg(it.value()).arg(it.key().isEmpty() ? QStringLiteral("?") : it.key());
    const int n = int(m_sources.size());
    return QStringLiteral("%1 source%2: %3").arg(n).arg(n == 1 ? "" : "s").arg(parts.join(QStringLiteral(", ")));
}

} // namespace qs
