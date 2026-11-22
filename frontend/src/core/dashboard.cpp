#include "core/dashboard.h"

#include "core/protocol_client.h"

namespace qs {

Dashboard::Dashboard(QObject *parent) : QObject(parent)
{
    connect(&m_leagues, &LeagueController::changeSucceeded, &m_rates, &RatesFeed::expectLeague);
    // The backend switched by itself: same loading behaviour as a user switch.
    connect(&m_leagues, &LeagueController::backendChanged, &m_rates, &RatesFeed::expectLeague);
    // A failed user change: if the backend's league moved meanwhile (push),
    // expect that one; a no-op when its rows are already shown.
    connect(&m_leagues, &LeagueController::changeFailed, this, [this] {
        if (m_leagues.connected())
            m_rates.expectLeague(m_leagues.current());
    });
}

void Dashboard::attach(ProtocolClient *client)
{
    m_leagues.attach(client);
    m_rates.attach(client);
    connect(client, &ProtocolClient::healthReceived, this,
            [this](const QJsonObject &payload) { m_health.setReport(payload); });
    connect(client, &ProtocolClient::closed, this, &Dashboard::connectionLost);
    connect(client, &ProtocolClient::handshakeFailed, this, &Dashboard::connectionLost);
}

void Dashboard::connectionLost()
{
    m_leagues.connectionLost();
    m_rates.connectionLost();
    m_health.setLive(false);
}

} // namespace qs
