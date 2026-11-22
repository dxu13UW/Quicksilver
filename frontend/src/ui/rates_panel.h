#pragma once
// The currency rates section of the dashboard (DASH-1, NFR-REL-3): a heading
// with the league, the source and the data's age, a STALE marker, a name
// filter, and either the sortable table or a message (waiting, loading,
// no rates). Updates keep the user's sort and scroll (the model updates rows
// in place).

#include <QWidget>

class QLabel;
class QLineEdit;
class QStackedWidget;
class QTableView;
class QTimer;

namespace qs {

class RatesFeed;
class RatesSortProxy;

class RatesPanel : public QWidget {
    Q_OBJECT
public:
    explicit RatesPanel(RatesFeed *feed, QWidget *parent = nullptr);

    QTableView *table() const { return m_table; }
    RatesSortProxy *proxy() const { return m_proxy; }
    // For tests and screenshots.
    bool showingTable() const;
    QString headingText() const;
    QString metaText() const;
    QString messageText() const;
    bool staleMarkerVisible() const;

public slots:
    void refresh();

private:
    RatesFeed *m_feed;
    RatesSortProxy *m_proxy;
    QLabel *m_heading;
    QLabel *m_meta;
    QLabel *m_staleChip;
    QLabel *m_offlineChip;
    QLineEdit *m_filter;
    QStackedWidget *m_stack;
    QTableView *m_table;
    QLabel *m_messageTitle;
    QLabel *m_messageBody;
    QTimer *m_tick;
};

} // namespace qs
