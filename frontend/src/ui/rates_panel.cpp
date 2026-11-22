#include "ui/rates_panel.h"

#include "core/dashboard_format.h"
#include "core/rates_feed.h"

#include <QHBoxLayout>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QStackedWidget>
#include <QTableView>
#include <QTimer>
#include <QVBoxLayout>

namespace qs {

namespace {
QLabel *chip(const QString &text, const char *bg, const QString &tip)
{
    auto *l = new QLabel(text);
    l->setStyleSheet(QStringLiteral("QLabel { background: %1; color: white; border-radius: 4px;"
                                    " padding: 1px 7px; font-weight: 600; }")
                         .arg(QLatin1String(bg)));
    l->setToolTip(tip);
    l->hide();
    return l;
}
} // namespace

RatesPanel::RatesPanel(RatesFeed *feed, QWidget *parent) : QWidget(parent), m_feed(feed)
{
    m_heading = new QLabel;
    QFont hf = m_heading->font();
    hf.setPointSizeF(hf.pointSizeF() * 1.25);
    hf.setBold(true);
    m_heading->setFont(hf);
    m_meta = new QLabel;
    m_meta->setStyleSheet(QStringLiteral("QLabel { color: #6b7280; }"));
    m_staleChip = chip(QStringLiteral("STALE"), "#c27c0e",
                       QStringLiteral("poe.ninja couldn't be reached on the last refresh. "
                                      "These are the last rates it returned."));
    m_offlineChip = chip(QStringLiteral("OFFLINE"), "#6b7280",
                         QStringLiteral("Not connected to the backend. These are the last rates received."));
    m_filter = new QLineEdit;
    m_filter->setPlaceholderText(QStringLiteral("Filter by name"));
    m_filter->setClearButtonEnabled(true);
    m_filter->setMaximumWidth(220);
    m_filter->setAccessibleName(QStringLiteral("Filter currencies by name"));

    auto *titleRow = new QHBoxLayout;
    titleRow->addWidget(m_heading);
    titleRow->addWidget(m_staleChip);
    titleRow->addWidget(m_offlineChip);
    titleRow->addStretch(1);
    titleRow->addWidget(m_filter);

    // Table page.
    m_proxy = new RatesSortProxy(this);
    m_proxy->setSourceModel(feed->model());
    m_table = new QTableView;
    m_table->setObjectName(QStringLiteral("ratesTable"));
    m_table->setModel(m_proxy);
    m_table->setSortingEnabled(true);
    m_table->sortByColumn(RatesModel::Chaos, Qt::DescendingOrder);
    m_table->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_table->setSelectionMode(QAbstractItemView::SingleSelection);
    m_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_table->setAlternatingRowColors(true);
    m_table->setTabKeyNavigation(false); // Tab leaves the table instead of walking its cells
    m_table->setAccessibleName(QStringLiteral("Currency rates"));
    m_table->setShowGrid(false);
    m_table->setWordWrap(false);
    m_table->verticalHeader()->hide();
    m_table->verticalHeader()->setDefaultSectionSize(m_table->fontMetrics().height() + 8);
    m_table->horizontalHeader()->setSectionResizeMode(QHeaderView::Interactive);
    m_table->horizontalHeader()->setSectionResizeMode(RatesModel::Name, QHeaderView::Stretch);
    m_table->horizontalHeader()->setHighlightSections(false);
    for (int c = RatesModel::Chaos; c < RatesModel::ColumnCount; ++c)
        m_table->setColumnWidth(c, 110);

    // Message page.
    m_messageTitle = new QLabel;
    QFont mf = m_messageTitle->font();
    mf.setPointSizeF(mf.pointSizeF() * 1.15);
    mf.setBold(true);
    m_messageTitle->setFont(mf);
    m_messageTitle->setAlignment(Qt::AlignCenter);
    m_messageTitle->setWordWrap(true);
    m_messageBody = new QLabel;
    m_messageBody->setAlignment(Qt::AlignCenter);
    m_messageBody->setWordWrap(true);
    m_messageBody->setStyleSheet(QStringLiteral("QLabel { color: #6b7280; }"));
    auto *msgPage = new QWidget;
    auto *msgLayout = new QVBoxLayout(msgPage);
    msgLayout->addStretch(1);
    msgLayout->addWidget(m_messageTitle);
    msgLayout->addWidget(m_messageBody);
    msgLayout->addStretch(2);

    m_stack = new QStackedWidget;
    m_stack->addWidget(m_table);
    m_stack->addWidget(msgPage);

    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->addLayout(titleRow);
    layout->addWidget(m_meta);
    layout->addWidget(m_stack, 1);

    connect(m_filter, &QLineEdit::textChanged, m_proxy, &QSortFilterProxyModel::setFilterFixedString);
    connect(feed, &RatesFeed::changed, this, &RatesPanel::refresh);
    // Re-render "updated N min ago" as time passes (display only).
    m_tick = new QTimer(this);
    m_tick->setInterval(15'000);
    connect(m_tick, &QTimer::timeout, this, &RatesPanel::refresh);
    m_tick->start();
    refresh();
}

bool RatesPanel::showingTable() const { return m_stack->currentWidget() == m_table; }
QString RatesPanel::headingText() const { return m_heading->text(); }
QString RatesPanel::metaText() const { return m_meta->text(); }
QString RatesPanel::messageText() const { return m_messageTitle->text() + QLatin1Char('\n') + m_messageBody->text(); }
bool RatesPanel::staleMarkerVisible() const { return !m_staleChip->isHidden(); }

void RatesPanel::refresh()
{
    const RatesFeed *f = m_feed;
    const QString league = f->league();
    m_heading->setText(league.isEmpty() ? QStringLiteral("Currency rates")
                                        : QStringLiteral("Currency rates · %1").arg(league));

    auto showMessage = [this](const QString &title, const QString &body) {
        m_messageTitle->setText(title);
        m_messageBody->setText(body);
        m_stack->setCurrentIndex(1);
    };

    m_staleChip->setVisible(f->state() == RatesFeed::State::Ready && f->stale());
    m_offlineChip->setVisible(f->state() == RatesFeed::State::Ready && !f->live());
    m_filter->setEnabled(f->state() == RatesFeed::State::Ready);

    switch (f->state()) {
    case RatesFeed::State::Waiting:
        m_meta->clear();
        showMessage(QStringLiteral("Waiting for the backend"),
                    QStringLiteral("Rates appear here once Quicksilver is connected."));
        return;
    case RatesFeed::State::Loading:
        m_meta->clear();
        showMessage(league.isEmpty() ? QStringLiteral("Loading rates…")
                                     : QStringLiteral("Loading rates for %1…").arg(league),
                    QStringLiteral("Prices come from poe.ninja through the backend."));
        return;
    case RatesFeed::State::Error:
        m_meta->clear();
        showMessage(league.isEmpty() ? QStringLiteral("No rates available")
                                     : QStringLiteral("No rates for %1").arg(league),
                    f->message() + QStringLiteral("\nIf rates become available, the table fills in by itself."));
        return;
    case RatesFeed::State::Ready:
        break;
    }

    QStringList meta;
    if (!f->source().isEmpty())
        meta << (f->source() == QLatin1String("poe_ninja") ? QStringLiteral("poe.ninja") : f->source());
    if (f->fetchedAt().isValid()) {
        const qint64 age = f->fetchedAt().secsTo(QDateTime::currentDateTimeUtc());
        meta << QStringLiteral("updated %1").arg(fmt::ago(age));
    }
    if (f->divineChaos())
        meta << QStringLiteral("1 divine = %1 chaos").arg(fmt::chaos(f->divineChaos()));
    if (f->stale())
        meta << QStringLiteral("the last refresh failed, so this is cached data");
    if (!f->live())
        meta << QStringLiteral("not connected");
    m_meta->setText(meta.join(QStringLiteral(" · ")));
    m_meta->setToolTip(f->fetchedAt().isValid()
                           ? QStringLiteral("Fetched %1").arg(
                                 f->fetchedAt().toLocalTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss")))
                           : QString());

    if (m_feed->model()->rowCount() == 0)
        showMessage(QStringLiteral("No rates in this update"),
                    QStringLiteral("poe.ninja returned an empty list for %1.").arg(league));
    else
        m_stack->setCurrentIndex(0);
}

} // namespace qs
