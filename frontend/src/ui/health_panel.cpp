#include "ui/health_panel.h"

#include "core/dashboard_format.h"
#include "core/health_model.h"

#include <QHeaderView>
#include <QHBoxLayout>
#include <QLabel>
#include <QPainter>
#include <QTableView>
#include <QVBoxLayout>

namespace qs {

QColor StatusBadgeDelegate::colorFor(const QString &status)
{
    if (status == QLatin1String("ok"))
        return QColor(0x2f, 0x9e, 0x62);
    if (status == QLatin1String("degraded"))
        return QColor(0xc2, 0x7c, 0x0e);
    if (status == QLatin1String("down"))
        return QColor(0xc8, 0x43, 0x3a);
    if (status == QLatin1String("idle"))
        return QColor(0x7b, 0x86, 0x99);
    return QColor(0xb0, 0xb4, 0xbb); // unknown / not connected
}

void StatusBadgeDelegate::paint(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const
{
    // Background (selection, alternate rows) from the style, then the pill.
    QStyleOptionViewItem opt(option);
    initStyleOption(&opt, index);
    opt.text.clear();
    QStyle *style = opt.widget ? opt.widget->style() : nullptr;
    if (style)
        style->drawControl(QStyle::CE_ItemViewItem, &opt, painter, opt.widget);

    const QString status = index.data(HealthModel::StatusRole).toString();
    const QString text = status.isEmpty() ? QStringLiteral("?") : status;
    QFont f = option.font;
    f.setBold(true);
    f.setPointSizeF(f.pointSizeF() * 0.9);
    const QFontMetrics fm(f);
    const int w = fm.horizontalAdvance(text) + 16;
    const int h = fm.height() + 4;
    const QRect pill(option.rect.left() + 6, option.rect.center().y() - h / 2 + 1, w, h);

    painter->save();
    painter->setRenderHint(QPainter::Antialiasing);
    painter->setPen(Qt::NoPen);
    painter->setBrush(colorFor(status));
    painter->drawRoundedRect(pill, h / 2.0, h / 2.0);
    painter->setPen(Qt::white);
    painter->setFont(f);
    painter->drawText(pill, Qt::AlignCenter, text);
    painter->restore();
}

QSize StatusBadgeDelegate::sizeHint(const QStyleOptionViewItem &option, const QModelIndex &index) const
{
    QFont f = option.font;
    f.setBold(true);
    const QFontMetrics fm(f);
    const QString status = index.data(HealthModel::StatusRole).toString();
    return {fm.horizontalAdvance(status) + 32, fm.height() + 10};
}

HealthPanel::HealthPanel(HealthModel *model, QWidget *parent) : QWidget(parent), m_model(model)
{
    auto *title = new QLabel(QStringLiteral("Data sources"));
    QFont tf = title->font();
    tf.setBold(true);
    tf.setPointSizeF(tf.pointSizeF() * 1.1);
    title->setFont(tf);
    m_summary = new QLabel;
    m_summary->setStyleSheet(QStringLiteral("QLabel { color: #6b7280; }"));

    m_table = new QTableView;
    m_table->setObjectName(QStringLiteral("healthTable"));
    m_table->setModel(model);
    m_table->setItemDelegateForColumn(HealthModel::Status, new StatusBadgeDelegate(m_table));
    m_table->setSelectionMode(QAbstractItemView::NoSelection);
    m_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_table->setFocusPolicy(Qt::NoFocus);
    m_table->setTabKeyNavigation(false);
    m_table->setAccessibleName(QStringLiteral("Data sources"));
    m_table->setShowGrid(false);
    m_table->setWordWrap(false);
    m_table->verticalHeader()->hide();
    m_table->horizontalHeader()->setHighlightSections(false);
    m_table->horizontalHeader()->setSectionResizeMode(QHeaderView::ResizeToContents);
    m_table->horizontalHeader()->setSectionResizeMode(HealthModel::Detail, QHeaderView::Stretch);

    auto *head = new QHBoxLayout;
    head->addWidget(title);
    head->addWidget(m_summary, 1);
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->addLayout(head);
    layout->addWidget(m_table, 1);

    connect(model, &HealthModel::reportChanged, this, &HealthPanel::refresh);
    refresh();
}

QString HealthPanel::summaryText() const
{
    return m_summary->text();
}

void HealthPanel::refresh()
{
    if (!m_model->hasReport()) {
        m_summary->setText(QStringLiteral("waiting for the first report"));
        return;
    }
    if (!m_model->live()) {
        m_summary->setText(QStringLiteral("not connected; last report %1")
                               .arg(fmt::ago(m_model->receivedAt().secsTo(QDateTime::currentDateTimeUtc()))));
        return;
    }
    m_summary->setText(QStringLiteral("%1 · backend up %2")
                           .arg(m_model->summary(), fmt::duration(m_model->uptimeS())));
}

} // namespace qs
