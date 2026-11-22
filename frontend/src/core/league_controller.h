#pragma once
// League selection logic (REQUIREMENTS DASH-2; PROTOCOL `leagues.list`,
// `league.set`, `welcome.league`). No widgets: the selector widget only
// mirrors this object and calls select() on a USER action.
//
// - attach(client): on every `welcome`, takes `welcome.league` as the current
//   league and asks for `leagues.list`.
// - select(id): sends `league.set` unless it's the current league, a change
//   is already pending, or there's no connection. Only one change is in
//   flight at a time, so replies can't race each other.
// - On `league.changed`: current = that league, changeSucceeded().
//   On an error: current stays the previous league, changeFailed() (the
//   selector reverts to current()).
// - Filling the list never sends anything.
// - A `league.changed` PUSH (id null: the backend chose or replaced the league
//   itself, PROTOCOL "league.changed push") becomes current() without sending
//   anything, and emits backendChanged(). While a user change is pending, the
//   pending choice stays shown and its reply decides; current() still follows
//   the push, so a failed change reverts to the backend's real league.

#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QVector>

namespace qs {

class ProtocolClient;
struct Reply;
struct WelcomeInfo;

struct League {
    QString id;
    QString text;
    bool operator==(const League &o) const { return id == o.id && text == o.text; }
};

class LeagueController : public QObject {
    Q_OBJECT
public:
    enum class ListState {
        NotLoaded,   // never connected
        Loading,     // leagues.list in flight
        Loaded,
        Unavailable, // leagues.list failed (listError() has the message)
    };
    Q_ENUM(ListState)

    explicit LeagueController(QObject *parent = nullptr);

    void attach(ProtocolClient *client);

    const QVector<League> &leagues() const { return m_leagues; }
    QString current() const { return m_current; }
    QString pending() const { return m_pending; } // league being switched to
    bool isPending() const { return !m_pending.isEmpty(); }
    ListState listState() const { return m_listState; }
    QString listError() const { return m_listError; }
    bool connected() const { return m_connected; }
    // Display text for an id (the id itself if it's not in the list).
    QString textFor(const QString &id) const;

public slots:
    // Returns true if a league.set was sent.
    bool select(const QString &id);
    // Asks for leagues.list again (e.g. a "Reload" click).
    void reload();
    // The connection went away (also called for silent closes).
    void connectionLost();

signals:
    // Anything shown changed: list, current, pending, list state.
    void changed();
    void changeStarted(const QString &league);
    void changeSucceeded(const QString &league);
    void changeFailed(const QString &league, const QString &code, const QString &message);
    // The backend switched league by itself (a league.changed push), and no
    // user change was pending.
    void backendChanged(const QString &league);
    // current() changed for any reason (welcome, leagues.result, league.changed).
    void currentChanged(const QString &league);

private:
    void onWelcome(const WelcomeInfo &welcome);
    void onPush(const QString &type, const QJsonObject &payload);
    void onLeaguesReply(quint64 epoch, quint64 changes, const Reply &reply);
    void onSetReply(quint64 epoch, const QString &league, const Reply &reply);
    void setCurrent(const QString &league);

    QPointer<ProtocolClient> m_client;
    QVector<League> m_leagues;
    QString m_current;
    QString m_pending;
    ListState m_listState = ListState::NotLoaded;
    QString m_listError;
    bool m_connected = false;
    quint64 m_epoch = 0; // bumped on every welcome / loss; stale replies are ignored
    // League changes so far (replies and pushes). A leagues.result requested before the
    // latest change carries an outdated `current`, so it's not applied.
    quint64 m_changes = 0;
};

} // namespace qs
