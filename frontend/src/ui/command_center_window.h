#pragma once
// The command center: a normal top-level window.
// - Top: the backend connection card (F1): status dot, headline, detail, Restart.
// - "Dashboard" tab (F2): league selector, currency rates, data source health.
// - "Backend log" tab: the tail of the backend's log.

#include "core/backend_connection.h"
#include "core/dashboard.h"

#include <QMainWindow>

class QLabel;
class QPlainTextEdit;
class QPushButton;
class QTabWidget;

namespace qs {

class LeagueSelector;
class RatesPanel;
class HealthPanel;

class CommandCenterWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit CommandCenterWindow(BackendConnection *connection, QWidget *parent = nullptr);
    ~CommandCenterWindow() override;

    Dashboard *dashboard() { return &m_dashboard; }
    LeagueSelector *leagueSelector() const { return m_leagueSelector; }
    RatesPanel *ratesPanel() const { return m_ratesPanel; }
    HealthPanel *healthPanel() const { return m_healthPanel; }

    // Dev aid: when set, a PNG of the window is saved there after each
    // dashboard change (QUICKSILVER_SNAPSHOT_DIR in main.cpp). Off by default.
    void setSnapshotDir(const QString &dir);

private:
    void showStatus(const BackendConnection::Status &status);
    void appendLog(const QString &line);
    void showAbout();
    void scheduleSnapshot();

    BackendConnection *m_connection;
    Dashboard m_dashboard;
    QLabel *m_dot = nullptr;
    QLabel *m_headline = nullptr;
    QLabel *m_detail = nullptr;
    QPushButton *m_restart = nullptr;
    QTabWidget *m_tabs = nullptr;
    LeagueSelector *m_leagueSelector = nullptr;
    RatesPanel *m_ratesPanel = nullptr;
    HealthPanel *m_healthPanel = nullptr;
    QPlainTextEdit *m_log = nullptr;
    QString m_snapshotDir;
    int m_snapshotCount = 0;
    bool m_snapshotQueued = false;
};

} // namespace qs
