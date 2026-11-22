#include "core/rates_feed.h"

#include "core/protocol_client.h"

#include <QLoggingCategory>

Q_LOGGING_CATEGORY(lcRates, "qs.rates")

namespace qs {

RatesFeed::RatesFeed(QObject *parent) : QObject(parent) {}

void RatesFeed::attach(ProtocolClient *client)
{
    if (m_client)
        m_client->disconnect(this);
    m_client = client;
    connect(client, &ProtocolClient::ready, this, &RatesFeed::onWelcome);
    connect(client, &ProtocolClient::pushReceived, this, &RatesFeed::onPush);
    connect(client, &ProtocolClient::serverError, this, &RatesFeed::onServerError);
    connect(client, &ProtocolClient::closed, this, &RatesFeed::connectionLost);
    connect(client, &ProtocolClient::handshakeFailed, this, &RatesFeed::connectionLost);
    if (client->isReady())
        onWelcome(client->welcome());
}

void RatesFeed::onWelcome(const WelcomeInfo &welcome)
{
    ++m_epoch;
    m_live = true;
    if (m_state != State::Ready) {
        // Nothing to show yet: wait for the subscribe reply. Keep rows we
        // already have (they're replaced by the reply).
        m_state = State::Loading;
        if (m_league.isEmpty() || m_league != welcome.league)
            m_league = welcome.league;
        m_message.clear();
        m_errorCode.clear();
    }
    emit changed();

    const quint64 epoch = m_epoch;
    QPointer<RatesFeed> self(this);
    qCInfo(lcRates) << "rates.subscribe";
    m_client->request(QStringLiteral("rates.subscribe"), {}, [self, epoch](const Reply &r) {
        if (self)
            self->onSubscribeReply(epoch, r);
    });
}

void RatesFeed::onSubscribeReply(quint64 epoch, const Reply &reply)
{
    if (epoch != m_epoch)
        return;
    if (reply.type == QLatin1String("rates.update")) {
        apply(reply.payload);
        return;
    }
    if (reply.isError()) {
        const QString code = reply.errorCode();
        if (code == QLatin1String("disconnected") || code == QLatin1String("not_connected"))
            return;
        // upstream_unavailable (or anything else): no rates for now. The
        // subscription stays active; data is pushed once it arrives.
        showError(m_league, code, reply.payload.value(QLatin1String("message")).toString());
        return;
    }
    qCWarning(lcRates) << "unexpected reply to rates.subscribe:" << reply.type;
}

void RatesFeed::onPush(const QString &type, const QJsonObject &payload)
{
    if (type == QLatin1String("rates.update"))
        apply(payload);
}

void RatesFeed::onServerError(const QString &code, const QString &message, const QJsonObject &payload)
{
    if (payload.value(QLatin1String("topic")).toString() != QLatin1String("rates"))
        return;
    const QJsonValue league = payload.value(QLatin1String("league"));
    showError(league.isString() ? league.toString() : m_league, code, message);
}

void RatesFeed::apply(const QJsonObject &payload)
{
    const auto snap = parseRatesUpdate(payload);
    if (!snap) {
        qCWarning(lcRates) << "ignoring malformed rates.update";
        return;
    }
    ++m_updates;
    m_model.setSnapshot(*snap);
    m_state = State::Ready;
    m_league = snap->league;
    m_source = snap->source;
    m_fetchedAt = snap->fetchedAt;
    m_stale = snap->stale;
    m_divineChaos = snap->divineChaos;
    m_message.clear();
    m_errorCode.clear();
    qCInfo(lcRates) << "rates.update" << m_league << snap->rows.size() << "rows" << (m_stale ? "(stale)" : "");
    emit changed();
}

void RatesFeed::showError(const QString &league, const QString &code, const QString &message)
{
    qCInfo(lcRates) << "no rates for" << league << ":" << code;
    m_model.clear();
    m_state = State::Error;
    m_league = league;
    m_errorCode = code;
    m_message = message.isEmpty() ? QStringLiteral("No rates are available right now.") : message;
    m_fetchedAt = {};
    m_stale = false;
    m_divineChaos.reset();
    emit changed();
}

void RatesFeed::expectLeague(const QString &league)
{
    if (league.isEmpty())
        return;
    if (m_state == State::Ready && m_model.league() == league)
        return;
    if (m_state == State::Error && m_league == league)
        return; // the error for this league may already be here
    m_model.clear();
    m_state = State::Loading;
    m_league = league;
    m_message.clear();
    m_errorCode.clear();
    m_fetchedAt = {};
    m_stale = false;
    m_divineChaos.reset();
    emit changed();
}

void RatesFeed::connectionLost()
{
    if (!m_live)
        return;
    ++m_epoch;
    m_live = false;
    if (m_state == State::Loading)
        m_state = State::Waiting;
    emit changed();
}

} // namespace qs
