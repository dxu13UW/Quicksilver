#pragma once
// The rates subscription (REQUIREMENTS DASH-1, NFR-REL-3; PROTOCOL
// `rates.subscribe`, `rates.update`, rates error push).
//
// - attach(client): on every `welcome`, sends `rates.subscribe` (so it
//   re-subscribes after each reconnect).
// - `rates.update` (the subscribe reply or a push) -> Ready, rows in the model.
// - `upstream_unavailable` on subscribe, or the rates error push
//   (`topic: "rates"`) -> Error: the table is cleared and message() says why.
//   A later `rates.update` replaces it.
// - expectLeague(id), called after a successful `league.set`: if the rows
//   shown belong to another league, they're cleared and the state is Loading
//   until that league's update or error arrives.
// - Losing the connection keeps the last rows (NFR-REL-3: last data rather
//   than an empty screen); live() goes false so the UI can say so.

#include "core/rates_model.h"

#include <QDateTime>
#include <QObject>
#include <QPointer>

namespace qs {

class ProtocolClient;
struct Reply;
struct WelcomeInfo;

class RatesFeed : public QObject {
    Q_OBJECT
public:
    enum class State {
        Waiting, // not connected, nothing to show
        Loading, // subscribed or league switched; no rows for that league yet
        Ready,   // rows shown (possibly stale, possibly not live)
        Error,   // no rates for league(): message() says why
    };
    Q_ENUM(State)

    explicit RatesFeed(QObject *parent = nullptr);

    void attach(ProtocolClient *client);

    RatesModel *model() { return &m_model; }
    State state() const { return m_state; }
    bool live() const { return m_live; }
    // The league shown, loading or failed (may be empty when unknown).
    QString league() const { return m_league; }
    QString message() const { return m_message; }
    QString errorCode() const { return m_errorCode; }
    // Metadata of the last rates.update (valid in Ready).
    QString source() const { return m_source; }
    QDateTime fetchedAt() const { return m_fetchedAt; }
    bool stale() const { return m_stale; }
    std::optional<double> divineChaos() const { return m_divineChaos; }
    int updates() const { return m_updates; } // rates.update count, for tests/diagnostics

public slots:
    void expectLeague(const QString &league);
    void connectionLost();

signals:
    void changed();

private:
    void onWelcome(const WelcomeInfo &welcome);
    void onPush(const QString &type, const QJsonObject &payload);
    void onServerError(const QString &code, const QString &message, const QJsonObject &payload);
    void onSubscribeReply(quint64 epoch, const Reply &reply);
    void apply(const QJsonObject &payload);
    void showError(const QString &league, const QString &code, const QString &message);

    QPointer<ProtocolClient> m_client;
    RatesModel m_model;
    State m_state = State::Waiting;
    bool m_live = false;
    QString m_league;
    QString m_message;
    QString m_errorCode;
    QString m_source;
    QDateTime m_fetchedAt;
    bool m_stale = false;
    std::optional<double> m_divineChaos;
    int m_updates = 0;
    quint64 m_epoch = 0;
};

} // namespace qs
