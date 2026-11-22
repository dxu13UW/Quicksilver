#pragma once
// The `health` push as a table (REQUIREMENTS CON-3, DASH-3): one row per source
// in the order the backend sent them (PROTOCOL: "The client shows the
// sources in the order given").
//
// Columns: source, status, last success, cache age, detail, rate limit.
// StatusRole carries the raw status ("idle"/"ok"/"degraded"/"down") for the
// badge delegate. While not live (disconnected), the last report stays
// visible but every row reports StatusRole "unknown".

#include <QAbstractTableModel>
#include <QDateTime>
#include <QJsonObject>
#include <QVector>

#include <optional>

namespace qs {

struct HealthSource {
    QString name;
    QString status;
    QDateTime lastSuccess;       // UTC; invalid for null
    std::optional<qint64> cacheAgeS;
    QString detail;
    bool hasRateLimit = false;
    QString rlPolicy;
    int rlQueued = 0;
    QDateTime rlRestrictedUntil; // UTC; invalid for null
};

class HealthModel : public QAbstractTableModel {
    Q_OBJECT
public:
    enum Column { Source, Status, LastSuccess, CacheAge, Detail, RateLimit, ColumnCount };
    enum Role { StatusRole = Qt::UserRole + 1 };

    explicit HealthModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    int columnCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;

    // `now` is when the report arrived (relative times are computed from it).
    void setReport(const QJsonObject &payload, const QDateTime &now = QDateTime::currentDateTimeUtc());
    void setLive(bool live);

    bool live() const { return m_live; }
    bool hasReport() const { return m_received.isValid(); }
    qint64 uptimeS() const { return m_uptimeS; }
    const QDateTime &receivedAt() const { return m_received; }
    const QVector<HealthSource> &sources() const { return m_sources; }

    // One line, e.g. "2 sources: 1 ok, 1 down".
    QString summary() const;
    // Display text for a rate-limit entry (empty when there is none).
    static QString rateLimitText(const HealthSource &s, const QDateTime &now);

signals:
    void reportChanged();

private:
    QVector<HealthSource> m_sources;
    QDateTime m_received;
    qint64 m_uptimeS = 0;
    bool m_live = false;
};

} // namespace qs
