#pragma once
// The command center: a normal top-level window. For F1 it shows the backend
// connection state, the raw health push, and the tail of the backend log.
// F2 adds the rates table, league selector and the real health panel.

#include "core/backend_connection.h"

#include <QMainWindow>

class QLabel;
class QPlainTextEdit;
class QPushButton;
class QTreeWidget;

namespace qs {

class CommandCenterWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit CommandCenterWindow(BackendConnection *connection, QWidget *parent = nullptr);

private:
    void showStatus(const BackendConnection::Status &status);
    void showHealth(const QJsonObject &payload);
    void appendLog(const QString &line);
    void showAbout();

    BackendConnection *m_connection;
    QLabel *m_dot = nullptr;
    QLabel *m_headline = nullptr;
    QLabel *m_detail = nullptr;
    QPushButton *m_restart = nullptr;
    QLabel *m_healthSummary = nullptr;
    QTreeWidget *m_sources = nullptr;
    QPlainTextEdit *m_log = nullptr;
};

} // namespace qs
