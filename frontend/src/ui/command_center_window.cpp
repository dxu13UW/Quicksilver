#include "ui/command_center_window.h"

#include "core/app_log.h"
#include "ui/health_panel.h"
#include "ui/league_selector.h"
#include "ui/rates_panel.h"

#include <QApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFontDatabase>
#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QMenuBar>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QSplitter>
#include <QStatusBar>
#include <QTabWidget>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>

namespace qs {

namespace {
QString dotStyle(const char *color)
{
    return QStringLiteral("QLabel { background: %1; border-radius: 6px; }").arg(QLatin1String(color));
}
} // namespace

CommandCenterWindow::CommandCenterWindow(BackendConnection *connection, QWidget *parent)
    : QMainWindow(parent), m_connection(connection)
{
    setWindowTitle(QStringLiteral("Quicksilver"));
    resize(960, 720);

    // --- Connection card (compact strip) ---
    m_dot = new QLabel;
    m_dot->setFixedSize(12, 12);
    m_headline = new QLabel;
    QFont hf = m_headline->font();
    hf.setBold(true);
    m_headline->setFont(hf);
    m_detail = new QLabel;
    m_detail->setWordWrap(true);
    m_detail->setTextInteractionFlags(Qt::TextSelectableByMouse);
    m_detail->setStyleSheet(QStringLiteral("QLabel { color: #6b7280; }"));
    m_restart = new QPushButton(QStringLiteral("Restart backend"));
    m_restart->setToolTip(QStringLiteral("Stop the backend and start a fresh one"));
    connect(m_restart, &QPushButton::clicked, m_connection, &BackendConnection::restart);

    auto *cardText = new QVBoxLayout;
    cardText->setSpacing(1);
    cardText->addWidget(m_headline);
    cardText->addWidget(m_detail);
    auto *card = new QFrame;
    card->setObjectName(QStringLiteral("connectionCard"));
    card->setFrameShape(QFrame::StyledPanel);
    auto *cardLayout = new QHBoxLayout(card);
    cardLayout->setContentsMargins(10, 6, 10, 6);
    cardLayout->addWidget(m_dot, 0, Qt::AlignVCenter);
    cardLayout->addSpacing(4);
    cardLayout->addLayout(cardText, 1);
    cardLayout->addWidget(m_restart, 0, Qt::AlignVCenter);

    // --- Dashboard tab ---
    m_dashboard.attach(m_connection->client());
    m_leagueSelector = new LeagueSelector(m_dashboard.leagues());
    m_ratesPanel = new RatesPanel(m_dashboard.rates());
    m_healthPanel = new HealthPanel(m_dashboard.health());

    auto *split = new QSplitter(Qt::Vertical);
    split->setChildrenCollapsible(false);
    split->addWidget(m_ratesPanel);
    split->addWidget(m_healthPanel);
    split->setStretchFactor(0, 3);
    split->setStretchFactor(1, 1);
    split->setSizes({480, 150});

    auto *dashPage = new QWidget;
    auto *dashLayout = new QVBoxLayout(dashPage);
    dashLayout->addWidget(m_leagueSelector);
    dashLayout->addSpacing(4);
    dashLayout->addWidget(split, 1);

    // --- Backend log tab ---
    m_log = new QPlainTextEdit;
    m_log->setReadOnly(true);
    m_log->setMaximumBlockCount(500);
    m_log->setLineWrapMode(QPlainTextEdit::NoWrap);
    m_log->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
    for (const QString &line : m_connection->process()->recentLog())
        m_log->appendPlainText(line);

    m_tabs = new QTabWidget;
    m_tabs->setDocumentMode(true);
    m_tabs->addTab(dashPage, QStringLiteral("Dashboard"));
    m_tabs->addTab(m_log, QStringLiteral("Backend log"));

    auto *central = new QWidget;
    auto *layout = new QVBoxLayout(central);
    layout->addWidget(card);
    layout->addWidget(m_tabs, 1);
    setCentralWidget(central);

    // --- Menus ---
    QMenu *fileMenu = menuBar()->addMenu(QStringLiteral("&File"));
    fileMenu->addAction(QStringLiteral("Open &log folder"), this, [] {
        QDesktopServices::openUrl(QUrl::fromLocalFile(applog::logDir()));
    });
    fileMenu->addSeparator();
    fileMenu->addAction(QStringLiteral("E&xit"), QKeySequence::Quit, qApp, &QApplication::quit);
    QMenu *helpMenu = menuBar()->addMenu(QStringLiteral("&Help"));
    helpMenu->addAction(QStringLiteral("&About Quicksilver"), this, &CommandCenterWindow::showAbout);

    statusBar()->showMessage(QStringLiteral("Client %1").arg(QStringLiteral(QS_CLIENT_VERSION)));

    connect(m_connection, &BackendConnection::statusChanged, this, &CommandCenterWindow::showStatus);
    connect(m_connection->process(), &BackendProcess::logLine, this, &CommandCenterWindow::appendLog);
    showStatus(m_connection->status());
}

CommandCenterWindow::~CommandCenterWindow()
{
    // The views use models owned by m_dashboard; remove them before it goes.
    delete takeCentralWidget();
}

void CommandCenterWindow::showStatus(const BackendConnection::Status &status)
{
    using P = BackendConnection::Phase;
    const char *color = "#9aa0a6";
    switch (status.phase) {
    case P::Idle: color = "#9aa0a6"; break;
    case P::StartingBackend:
    case P::Connecting: color = "#e0a800"; break;
    case P::Connected: color = "#2e9d5b"; break;
    case P::Disconnected: color = "#e07b00"; break;
    case P::Failed: color = "#c93c3c"; break;
    }
    m_dot->setStyleSheet(dotStyle(color));
    m_headline->setText(status.headline.isEmpty() ? QStringLiteral("Not started") : status.headline);
    m_detail->setText(status.detail);
    m_detail->setVisible(!status.detail.isEmpty());
    // Covers silent closes (Restart, shutdown) the client doesn't signal.
    if (status.phase != P::Connected)
        m_dashboard.connectionLost();
}

void CommandCenterWindow::appendLog(const QString &line)
{
    m_log->appendPlainText(line);
}

void CommandCenterWindow::setSnapshotDir(const QString &dir)
{
    m_snapshotDir = dir;
    if (dir.isEmpty())
        return;
    QDir().mkpath(dir);
    connect(m_dashboard.rates(), &RatesFeed::changed, this, &CommandCenterWindow::scheduleSnapshot);
    connect(m_dashboard.leagues(), &LeagueController::changed, this, &CommandCenterWindow::scheduleSnapshot);
}

void CommandCenterWindow::scheduleSnapshot()
{
    if (m_snapshotQueued || m_snapshotDir.isEmpty())
        return;
    m_snapshotQueued = true;
    // Let the layout settle first.
    QTimer::singleShot(400, this, [this] {
        m_snapshotQueued = false;
        const QString path =
            QDir(m_snapshotDir).filePath(QStringLiteral("dashboard-%1.png").arg(++m_snapshotCount, 2, 10, QLatin1Char('0')));
        grab().save(path);
        qInfo().noquote() << "snapshot" << path;
    });
}

void CommandCenterWindow::showAbout()
{
    QMessageBox::about(
        this, QStringLiteral("About Quicksilver"),
        QStringLiteral("<p><b>Quicksilver %1</b><br>A companion app for Path of Exile.</p>"
                       "<p>This product isn't affiliated with or endorsed by Grinding Gear Games in any way.</p>"
                       "<p>Logs are kept in:<br>%2</p>")
            .arg(QStringLiteral(QS_CLIENT_VERSION), QDir::toNativeSeparators(applog::logDir()).toHtmlEscaped()));
}

} // namespace qs
