#pragma once
// Currency rates for the dashboard (REQUIREMENTS DASH-1, NFR-REL-3).
//
// - RatesSnapshot / parseRatesUpdate(): the PROTOCOL `rates.update` payload.
// - RatesModel: the rows as a table (name, chaos, divine, 7-day change,
//   volume). setSnapshot() updates rows IN PLACE, keyed by `id`, when the
//   league is unchanged, so a sort proxy and the view's scroll position
//   survive a refresh. A different league replaces everything.
// - RatesSortProxy: numeric sorting via RatesModel::SortRole; null values
//   (change_7d / volume may be null) always go to the bottom; ties keep the
//   backend's order (chaos, highest first).

#include <QAbstractTableModel>
#include <QDateTime>
#include <QJsonObject>
#include <QSortFilterProxyModel>
#include <QString>
#include <QVector>

#include <optional>

namespace qs {

struct RateRow {
    QString id;
    QString name;
    std::optional<double> chaos;
    std::optional<double> divine;
    std::optional<double> change7d;
    std::optional<double> volumeChaos;
};

struct RatesSnapshot {
    QString league;
    QString source;
    QDateTime fetchedAt; // UTC; invalid if missing
    bool stale = false;
    std::optional<double> divineChaos;
    QVector<RateRow> rows; // backend order
};

// nullopt if the payload has no "league" string or no "rates" array. Rows
// without an id are skipped.
std::optional<RatesSnapshot> parseRatesUpdate(const QJsonObject &payload);

class RatesModel : public QAbstractTableModel {
    Q_OBJECT
public:
    enum Column { Name, Chaos, Divine, Change7d, Volume, ColumnCount };
    enum Role {
        SortRole = Qt::UserRole + 1, // double, lower-cased name, or invalid for null
        RankRole,                    // int: position in the latest payload
        IdRole,                      // QString
    };

    explicit RatesModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    int columnCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;

    void setSnapshot(const RatesSnapshot &snapshot);
    void clear();

    // Metadata of the snapshot shown (empty league when cleared).
    const QString &league() const { return m_league; }
    const RateRow *row(int r) const { return (r >= 0 && r < m_rows.size()) ? &m_rows[r] : nullptr; }
    int rowOf(const QString &id) const;

private:
    QVector<RateRow> m_rows;
    QVector<int> m_rank;
    QString m_league;
};

class RatesSortProxy : public QSortFilterProxyModel {
    Q_OBJECT
public:
    explicit RatesSortProxy(QObject *parent = nullptr);

protected:
    bool lessThan(const QModelIndex &left, const QModelIndex &right) const override;
};

} // namespace qs
