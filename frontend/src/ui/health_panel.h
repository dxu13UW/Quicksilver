#pragma once
// Data source health (CON-3, DASH-3): one row per source in the backend's
// order, with a coloured status badge, last success, cache age, detail and
// rate-limit state. While disconnected it keeps the last report, greyed out.

#include <QStyledItemDelegate>
#include <QWidget>

class QLabel;
class QTableView;

namespace qs {

class HealthModel;

// Paints HealthModel::StatusRole as a rounded pill.
class StatusBadgeDelegate : public QStyledItemDelegate {
    Q_OBJECT
public:
    using QStyledItemDelegate::QStyledItemDelegate;
    void paint(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const override;
    QSize sizeHint(const QStyleOptionViewItem &option, const QModelIndex &index) const override;
    static QColor colorFor(const QString &status);
};

class HealthPanel : public QWidget {
    Q_OBJECT
public:
    explicit HealthPanel(HealthModel *model, QWidget *parent = nullptr);
    QTableView *table() const { return m_table; }
    QString summaryText() const;

private:
    void refresh();

    HealthModel *m_model;
    QLabel *m_summary;
    QTableView *m_table;
};

} // namespace qs
