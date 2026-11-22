#include "core/rates_model.h"

#include "core/dashboard_format.h"

#include <QBrush>
#include <QColor>
#include <QHash>
#include <QJsonArray>

#include <cmath>

namespace qs {

std::optional<RatesSnapshot> parseRatesUpdate(const QJsonObject &p)
{
    const QJsonValue league = p.value(QLatin1String("league"));
    const QJsonValue rates = p.value(QLatin1String("rates"));
    if (!league.isString() || !rates.isArray())
        return std::nullopt;
    RatesSnapshot s;
    s.league = league.toString();
    s.source = p.value(QLatin1String("source")).toString();
    s.fetchedAt = fmt::parseTimestamp(p.value(QLatin1String("fetched_at")));
    s.stale = p.value(QLatin1String("stale")).toBool();
    s.divineChaos = fmt::optionalNumber(p.value(QLatin1String("divine_chaos")));
    for (const QJsonValue &v : rates.toArray()) {
        const QJsonObject o = v.toObject();
        RateRow r;
        r.id = o.value(QLatin1String("id")).toString();
        if (r.id.isEmpty())
            continue;
        r.name = o.value(QLatin1String("name")).toString(r.id);
        r.chaos = fmt::optionalNumber(o.value(QLatin1String("chaos")));
        r.divine = fmt::optionalNumber(o.value(QLatin1String("divine")));
        r.change7d = fmt::optionalNumber(o.value(QLatin1String("change_7d")));
        r.volumeChaos = fmt::optionalNumber(o.value(QLatin1String("volume_chaos")));
        s.rows.append(r);
    }
    return s;
}

RatesModel::RatesModel(QObject *parent) : QAbstractTableModel(parent) {}

int RatesModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_rows.size());
}

int RatesModel::columnCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : ColumnCount;
}

int RatesModel::rowOf(const QString &id) const
{
    for (int i = 0; i < m_rows.size(); ++i)
        if (m_rows[i].id == id)
            return i;
    return -1;
}

QVariant RatesModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_rows.size())
        return {};
    const RateRow &r = m_rows[index.row()];
    const auto num = [](const std::optional<double> &v) { return v ? QVariant(*v) : QVariant(); };

    switch (role) {
    case Qt::DisplayRole:
        switch (index.column()) {
        case Name: return r.name;
        case Chaos: return fmt::chaos(r.chaos);
        case Divine: return fmt::divine(r.divine);
        case Change7d: return fmt::percentChange(r.change7d);
        case Volume: return fmt::volume(r.volumeChaos);
        }
        break;
    case SortRole:
        switch (index.column()) {
        case Name: return r.name.toLower();
        case Chaos: return num(r.chaos);
        case Divine: return num(r.divine);
        case Change7d: return num(r.change7d);
        case Volume: return num(r.volumeChaos);
        }
        break;
    case RankRole:
        return m_rank.value(index.row());
    case IdRole:
        return r.id;
    case Qt::TextAlignmentRole:
        if (index.column() != Name)
            return QVariant::fromValue(Qt::AlignRight | Qt::AlignVCenter);
        break;
    case Qt::ForegroundRole:
        if (index.column() == Change7d && r.change7d) {
            const double v = std::round(*r.change7d * 10) / 10;
            if (v > 0)
                return QBrush(QColor(0x2f, 0x9e, 0x62));
            if (v < 0)
                return QBrush(QColor(0xc8, 0x43, 0x3a));
        }
        break;
    case Qt::ToolTipRole:
        if (index.column() == Chaos && r.chaos)
            return QStringLiteral("%1 chaos").arg(*r.chaos, 0, 'f', 4);
        if (index.column() == Volume && r.volumeChaos)
            return QStringLiteral("%1 chaos traded (poe.ninja volume)").arg(*r.volumeChaos, 0, 'f', 0);
        break;
    default:
        break;
    }
    return {};
}

QVariant RatesModel::headerData(int section, Qt::Orientation orientation, int role) const
{
    if (orientation != Qt::Horizontal)
        return {};
    if (role == Qt::DisplayRole) {
        switch (section) {
        case Name: return QStringLiteral("Currency");
        case Chaos: return QStringLiteral("Chaos");
        case Divine: return QStringLiteral("Divine");
        case Change7d: return QStringLiteral("7-day change");
        case Volume: return QStringLiteral("Volume");
        }
    }
    if (role == Qt::ToolTipRole) {
        switch (section) {
        case Chaos: return QStringLiteral("Price in Chaos Orbs");
        case Divine: return QStringLiteral("Price in Divine Orbs");
        case Change7d: return QStringLiteral("Price change over the last 7 days");
        case Volume: return QStringLiteral("Traded volume, in chaos");
        }
    }
    if (role == Qt::TextAlignmentRole && section != Name)
        return QVariant::fromValue(Qt::AlignRight | Qt::AlignVCenter);
    return {};
}

void RatesModel::clear()
{
    m_league.clear();
    if (m_rows.isEmpty())
        return;
    beginResetModel();
    m_rows.clear();
    m_rank.clear();
    endResetModel();
}

void RatesModel::setSnapshot(const RatesSnapshot &s)
{
    if (s.league != m_league || m_rows.isEmpty()) {
        // Another league (or nothing shown yet): replace everything.
        beginResetModel();
        m_league = s.league;
        m_rows = s.rows;
        m_rank.resize(m_rows.size());
        for (int i = 0; i < m_rank.size(); ++i)
            m_rank[i] = i;
        endResetModel();
        return;
    }

    // Same league: update in place, keyed by id, so views keep their state.
    QHash<QString, int> incoming;
    for (int i = 0; i < s.rows.size(); ++i)
        incoming.insert(s.rows[i].id, i);

    // 1. Rows that disappeared, removed from the bottom up.
    for (int i = int(m_rows.size()) - 1; i >= 0; --i) {
        if (!incoming.contains(m_rows[i].id)) {
            beginRemoveRows({}, i, i);
            m_rows.removeAt(i);
            m_rank.removeAt(i);
            endRemoveRows();
        }
    }
    // 2. Rows that stay: new values and rank.
    QHash<QString, int> present;
    for (int i = 0; i < m_rows.size(); ++i) {
        const int src = incoming.value(m_rows[i].id);
        m_rows[i] = s.rows[src];
        m_rank[i] = src;
        present.insert(m_rows[i].id, i);
    }
    if (!m_rows.isEmpty())
        emit dataChanged(index(0, 0), index(int(m_rows.size()) - 1, ColumnCount - 1));
    // 3. New rows, appended in backend order.
    QVector<int> added;
    for (int i = 0; i < s.rows.size(); ++i)
        if (!present.contains(s.rows[i].id))
            added.append(i);
    if (!added.isEmpty()) {
        const int first = int(m_rows.size());
        beginInsertRows({}, first, first + int(added.size()) - 1);
        for (int src : added) {
            m_rows.append(s.rows[src]);
            m_rank.append(src);
        }
        endInsertRows();
    }
}

RatesSortProxy::RatesSortProxy(QObject *parent) : QSortFilterProxyModel(parent)
{
    setSortRole(RatesModel::SortRole);
    setDynamicSortFilter(true);
    setFilterCaseSensitivity(Qt::CaseInsensitive);
    setFilterKeyColumn(RatesModel::Name);
}

bool RatesSortProxy::lessThan(const QModelIndex &left, const QModelIndex &right) const
{
    const QVariant a = left.data(RatesModel::SortRole);
    const QVariant b = right.data(RatesModel::SortRole);
    const bool desc = sortOrder() == Qt::DescendingOrder;
    // Qt sorts descending by asking lessThan(right, left), so "goes last"
    // means "greater" in ascending order and "less" in descending order.
    if (!a.isValid() && b.isValid())
        return desc;
    if (a.isValid() && !b.isValid())
        return !desc;
    if (a.isValid() && b.isValid()) {
        if (a.typeId() == QMetaType::Double) {
            const double x = a.toDouble(), y = b.toDouble();
            if (x != y)
                return x < y;
        } else {
            const int c = QString::localeAwareCompare(a.toString(), b.toString());
            if (c != 0)
                return c < 0;
        }
    }
    // Tie: keep the backend's order in either direction.
    const int ra = left.data(RatesModel::RankRole).toInt();
    const int rb = right.data(RatesModel::RankRole).toInt();
    return desc ? ra > rb : ra < rb;
}

} // namespace qs
