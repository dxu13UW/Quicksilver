// Quicksilver.exe: starts the backend, connects to it, shows the command center.

#include "core/app_log.h"
#include "core/backend_connection.h"
#include "core/backend_locator.h"
#include "ui/command_center_window.h"

#include <QApplication>
#include <QIcon>
#include <QLoggingCategory>
#include <QProcessEnvironment>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("Quicksilver"));
    QApplication::setApplicationVersion(QStringLiteral(QS_CLIENT_VERSION));

    // Window and taskbar icon (title bar, Alt+Tab, dialogs). The exe's own icon
    // in Explorer comes from resources/quicksilver.rc.
    QIcon appIcon;
    for (int size : {16, 24, 32, 48, 64, 128, 256})
        appIcon.addFile(QStringLiteral(":/icons/quicksilver_%1.png").arg(size), QSize(size, size));
    QApplication::setWindowIcon(appIcon);

    qs::applog::installClientLog();
    qs::applog::rotateBackendLog();
    qInfo() << "Quicksilver" << QS_CLIENT_VERSION << "starting; logs in" << qs::applog::logDir();

    const auto env = QProcessEnvironment::systemEnvironment();
    const qs::BackendCommand command =
        qs::BackendLocator::resolve(env, QApplication::applicationDirPath(), QStringLiteral(QS_SOURCE_DIR));

    qs::BackendConnection connection(command);
    connection.process()->setLogFilePath(qs::applog::backendLogPath());
    bool okTimeout = false;
    const int readyTimeoutS = env.value(QStringLiteral("QUICKSILVER_READY_TIMEOUT_S")).toInt(&okTimeout);
    if (okTimeout && readyTimeoutS > 0)
        connection.process()->setReadyTimeoutMs(readyTimeoutS * 1000);

    qs::CommandCenterWindow window(&connection);
    // Dev aid: save a PNG of the window after each dashboard change.
    window.setSnapshotDir(env.value(QStringLiteral("QUICKSILVER_SNAPSHOT_DIR")));
    window.show();
    connection.start();

    const int rc = app.exec();
    window.hide();
    connection.shutdown(); // closes the backend's stdin, waits up to 3 s, then ends its job
    qInfo() << "Quicksilver exiting";
    return rc;
}
