#include "core/league_controller.h"

#include "core/protocol_client.h"

#include <QJsonArray>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(lcLeague, "qs.league")

namespace qs {

namespace {
bool isConnectionLoss(const QString &code)
{
    return code == QLatin1String("disconnected") || code == QLatin1String("not_connected");
}
} // namespace

LeagueController::LeagueController(QObject *parent) : QObject(parent) {}

void LeagueController::attach(ProtocolClient *client)
{
    if (m_client)
        m_client->disconnect(this);
    m_client = client;
    connect(client, &ProtocolClient::ready, this, &LeagueController::onWelcome);
    connect(client, &ProtocolClient::pushReceived, this, &LeagueController::onPush);
    connect(client, &ProtocolClient::closed, this, &LeagueController::connectionLost);
    connect(client, &ProtocolClient::handshakeFailed, this, &LeagueController::connectionLost);
    if (client->isReady())
        onWelcome(client->welcome());
}

QString LeagueController::textFor(const QString &id) const
{
    for (const League &l : m_leagues)
        if (l.id == id)
            return l.text;
    return id;
}

void LeagueController::setCurrent(const QString &league)
{
    if (league == m_current)
        return;
    m_current = league;
    emit currentChanged(league);
}

void LeagueController::onWelcome(const WelcomeInfo &welcome)
{
    ++m_epoch;
    m_connected = true;
    m_pending.clear();
    setCurrent(welcome.league);
    reload();
}

void LeagueController::onPush(const QString &type, const QJsonObject &payload)
{
    if (type != QLatin1String("league.changed"))
        return;
    const QString league = payload.value(QLatin1String("league")).toString();
    if (league.isEmpty() || !m_connected)
        return;
    // A leagues.result already in flight now carries an outdated `current`.
    ++m_changes;
    if (league == m_current)
        return; // already shown
    qCInfo(lcLeague) << "league.changed push:" << league << (isPending() ? "(user change pending)" : "");
    setCurrent(league);
    if (!isPending())
        emit backendChanged(league);
    emit changed();
}

void LeagueController::connectionLost()
{
    if (!m_connected)
        return;
    ++m_epoch;
    m_connected = false;
    const QString wasPending = m_pending;
    m_pending.clear();
    if (m_listState == ListState::Loading)
        m_listState = m_leagues.isEmpty() ? ListState::NotLoaded : ListState::Loaded;
    if (!wasPending.isEmpty())
        emit changeFailed(wasPending, QStringLiteral("disconnected"),
                          QStringLiteral("The connection to the backend dropped, so the league wasn't changed."));
    emit changed();
}

void LeagueController::reload()
{
    if (!m_client || !m_client->isReady())
        return;
    m_listState = ListState::Loading;
    m_listError.clear();
    emit changed();
    const quint64 epoch = m_epoch;
    const quint64 changes = m_changes;
    QPointer<LeagueController> self(this);
    m_client->request(QStringLiteral("leagues.list"), {}, [self, epoch, changes](const Reply &r) {
        if (self)
            self->onLeaguesReply(epoch, changes, r);
    });
}

void LeagueController::onLeaguesReply(quint64 epoch, quint64 changes, const Reply &reply)
{
    if (epoch != m_epoch)
        return;
    if (reply.isError()) {
        if (isConnectionLoss(reply.errorCode()))
            return; // connectionLost() handles it
        m_listState = ListState::Unavailable;
        m_listError = reply.payload.value(QLatin1String("message")).toString();
        qCInfo(lcLeague) << "leagues.list failed:" << reply.errorCode();
        emit changed();
        return;
    }
    if (reply.type != QLatin1String("leagues.result")) {
        qCWarning(lcLeague) << "unexpected reply to leagues.list:" << reply.type;
        return;
    }
    QVector<League> list;
    for (const QJsonValue &v : reply.payload.value(QLatin1String("leagues")).toArray()) {
        const QJsonObject o = v.toObject();
        League l{o.value(QLatin1String("id")).toString(), o.value(QLatin1String("text")).toString()};
        if (l.id.isEmpty())
            continue;
        if (l.text.isEmpty())
            l.text = l.id;
        list.append(l);
    }
    m_leagues = list;
    m_listState = ListState::Loaded;
    // `current` may be null. Replies can arrive out of order (PROTOCOL
    // Envelope): a list requested before a league change finished, or while
    // one is in flight, has an outdated `current`.
    if (!isPending() && changes == m_changes)
        setCurrent(reply.payload.value(QLatin1String("current")).toString());
    qCInfo(lcLeague) << "leagues:" << m_leagues.size() << "current:" << m_current;
    emit changed();
}

bool LeagueController::select(const QString &id)
{
    if (id.isEmpty() || id == m_current || isPending() || !m_client || !m_client->isReady())
        return false;
    m_pending = id;
    qCInfo(lcLeague) << "league.set" << id;
    emit changeStarted(id);
    emit changed();
    const quint64 epoch = m_epoch;
    QPointer<LeagueController> self(this);
    m_client->request(QStringLiteral("league.set"), QJsonObject{{QStringLiteral("league"), id}},
                      [self, epoch, id](const Reply &r) {
                          if (self)
                              self->onSetReply(epoch, id, r);
                      });
    return true;
}

void LeagueController::onSetReply(quint64 epoch, const QString &league, const Reply &reply)
{
    if (epoch != m_epoch)
        return;
    // A dropped connection is reported by connectionLost(), which needs to
    // still see the pending league.
    if (reply.isError() && isConnectionLoss(reply.errorCode()))
        return;
    m_pending.clear();
    if (reply.isError()) {
        qCInfo(lcLeague) << "league.set failed:" << reply.errorCode();
        emit changeFailed(league, reply.errorCode(), reply.payload.value(QLatin1String("message")).toString());
        emit changed();
        return;
    }
    const QString confirmed = reply.payload.value(QLatin1String("league")).toString(league);
    ++m_changes;
    setCurrent(confirmed);
    emit changeSucceeded(confirmed);
    emit changed();
}

} // namespace qs
