#pragma once
// The command center dashboard's state, without widgets (F2): the league
// selection, the rates subscription and the health report, all fed by one
// ProtocolClient. The UI only renders this and forwards user actions.
//
// Wiring: a successful league change tells the rates feed which league to
// expect next, so the table shows "loading" instead of the old league's rows.

#include "core/health_model.h"
#include "core/league_controller.h"
#include "core/rates_feed.h"

#include <QObject>

namespace qs {

class ProtocolClient;

class Dashboard : public QObject {
    Q_OBJECT
public:
    explicit Dashboard(QObject *parent = nullptr);

    void attach(ProtocolClient *client);

    LeagueController *leagues() { return &m_leagues; }
    RatesFeed *rates() { return &m_rates; }
    HealthModel *health() { return &m_health; }

public slots:
    // For closes the client doesn't signal (ProtocolClient::close(), e.g. a
    // user restart). Safe to call more than once.
    void connectionLost();

private:
    LeagueController m_leagues;
    RatesFeed m_rates;
    HealthModel m_health;
};

} // namespace qs
