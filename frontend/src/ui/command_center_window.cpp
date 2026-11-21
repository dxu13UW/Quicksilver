#include "ui/command_center_window.h"

#include "core/app_log.h"

#include <QApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFontDatabase>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLabel>
#include <QMenuBar>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QSplitter>
#include <QStatusBar>
#include <QTreeWidget>
#include <QUrl>
#include <QVBoxLayout>

namespace qs {

namespace {
QString dotStyle(const char *color)
{
    return QStringLiteral("QLabel { background: %1; border-radius: 7px; }").arg(QLatin1String(color));
}

QString valueText(const QJsonValue &v, const QString &suffix = {})
{
    if (v.isNull() || v.isUndefined())
        return QStringLiteral("–");
    if (v.isDouble())
        return QString::number(v.toDouble(), 'f', 0) + suffix;
    if (v.isString())
        return v.toString() + suffix;
    return QString::fromUtf8(QJsonDocument(v.toObject()).toJson(QJsonDocument::Compact));
}
} // namespace

CommandCenterWindow::CommandCenterWindow(BackendConnection *connection, QWidget *parent)
    : QMainWindow(parent), m_connection(connection)
{
    setWindowTitle(QStringLiteral("Quicksilver"));
    resize(820, 600);

    // --- Connection card ---
    m_dot = new QLabel;
    m_dot->setFixedSize(14, 14);
    m_headline = new QLabel;
    QFont hf = m_headline->font();
    hf.setPointSizeF(hf.pointSizeF() * 1.35);
    hf.setBold(true);
    m_headline->setFont(hf);
    m_headline->setWordWrap(true);
    m_detail = new QLabel;
    m_detail->setWordWrap(true);
    m_detail->setTextInteractionFlags(Qt::TextSelectableByMouse);
    m_restart = new QPushButton(QStringLiteral("Restart backend"));
    m_restart->setToolTip(QStringLiteral("Stop the backend and start a fresh one"));
    connect(m_restart, &QPushButton::clicked, m_connection, &BackendConnection::restart);

    auto *titleRow = new QHBoxLayout;
    titleRow->addWidget(m_dot, 0, Qt::AlignVCenter);
    titleRow->addWidget(m_headline, 1);
    titleRow->addWidget(m_restart, 0, Qt::AlignTop);
    auto *cardLayout = new QVBoxLayout;
    cardLayout->addLayout(titleRow);
    cardLayout->addWidget(m_detail);
    auto *card = new QGroupBox(QStringLiteral("Backend connection"));
    card->setLayout(cardLayout);

    // --- Health (raw for F1) ---
    m_healthSummary = new QLabel(QStringLiteral("No health report yet."));
    m_sources = new QTreeWidget;
    m_sources->setRootIsDecorated(false);
    m_sources->setHeaderLabels({QStringLiteral("Source"), QStringLiteral("Status"), QStringLiteral("Last success"),
                                QStringLiteral("Cache age"), QStringLiteral("Detail"),
                                QStringLiteral("Rate limit")});
    m_sources->header()->setSectionResizeMode(QHeaderView::ResizeToContents);
    auto *healthLayout = new QVBoxLayout;
    healthLayout->addWidget(m_healthSummary);
    healthLayout->addWidget(m_sources);
    auto *health = new QGroupBox(QStringLiteral("Data sources (raw health report)"));
    health->setLayout(healthLayout);

    // --- Backend log tail ---
    m_log = new QPlainTextEdit;
    m_log->setReadOnly(true);
    m_log->setMaximumBlockCount(500);
    m_log->setLineWrapMode(QPlainTextEdit::NoWrap);
    m_log->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
    for (const QString &line : m_connection->process()->recentLog())
        m_log->appendPlainText(line);
    auto *logLayout = new QVBoxLayout;
    logLayout->addWidget(m_log);
    auto *logBox = new QGroupBox(QStringLiteral("Backend log"));
    logBox->setLayout(logLayout);

    auto *split = new QSplitter(Qt::Vertical);
    split->addWidget(health);
    split->addWidget(logBox);
    split->setStretchFactor(0, 1);
    split->setStretchFactor(1, 2);

    auto *central = new QWidget;
    auto *layout = new QVBoxLayout(central);
    layout->addWidget(card);
    layout->addWidget(split, 1);
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
    connect(m_connection->client(), &ProtocolClient::healthReceived, this, &CommandCenterWindow::showHealth);
    connect(m_connection->process(), &BackendProcess::logLine, this, &CommandCenterWindow::appendLog);
    showStatus(m_connection->status());
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
    if (status.phase != P::Connected) {
        m_healthSummary->setText(QStringLiteral("No live health report (not connected)."));
        m_sources->setEnabled(false);
    } else {
        m_sources->setEnabled(true);
    }
}

void CommandCenterWindow::showHealth(const QJsonObject &payload)
{
    m_healthSummary->setText(
        QStringLiteral("Backend up for %1 s").arg(payload.value(QLatin1String("uptime_s")).toInt()));
    m_sources->clear();
    // PROTOCOL: show the sources in the order given.
    for (const QJsonValue &v : payload.value(QLatin1String("sources")).toArray()) {
        const QJsonObject s = v.toObject();
        auto *item = new QTreeWidgetItem(m_sources);
        item->setText(0, s.value(QLatin1String("name")).toString());
        item->setText(1, s.value(QLatin1String("status")).toString());
        item->setText(2, valueText(s.value(QLatin1String("last_success"))));
        item->setText(3, valueText(s.value(QLatin1String("cache_age_s")), QStringLiteral(" s")));
        item->setText(4, valueText(s.value(QLatin1String("detail"))));
        item->setText(5, valueText(s.value(QLatin1String("rate_limit"))));
    }
}

void CommandCenterWindow::appendLog(const QString &line)
{
    m_log->appendPlainText(line);
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
