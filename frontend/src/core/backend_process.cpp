#include "core/backend_process.h"

#include "core/protocol_codec.h"
#include "platform/child_stdin.h"
#include "platform/process_job.h"

#include <QDateTime>
#include <QLoggingCategory>
#include <QProcessEnvironment>

Q_LOGGING_CATEGORY(lcBackend, "qs.backend")

namespace qs {

namespace {
constexpr int kRecentLines = 500;
constexpr int kMaxLineBytes = 64 * 1024; // a "line" longer than this is flushed as is
} // namespace

BackendProcess::BackendProcess(QObject *parent) : QObject(parent)
{
    m_readyTimer.setSingleShot(true);
    connect(&m_readyTimer, &QTimer::timeout, this, &BackendProcess::onReadyTimeout);
}

BackendProcess::~BackendProcess()
{
    stop();
}

qint64 BackendProcess::processId() const
{
    return m_process ? m_process->processId() : 0;
}

void BackendProcess::appendLog(const QString &line)
{
    m_recent.append(line);
    if (m_recent.size() > kRecentLines)
        m_recent.remove(0, m_recent.size() - kRecentLines);
    if (m_logFile.isOpen()) {
        m_logFile.write(line.toUtf8());
        m_logFile.write("\n");
        m_logFile.flush();
    }
    emit logLine(line);
}

void BackendProcess::start(const BackendCommand &command)
{
    stop();

    if (!m_logFilePath.isEmpty() && !m_logFile.isOpen()) {
        m_logFile.setFileName(m_logFilePath);
        if (!m_logFile.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text))
            qCWarning(lcBackend) << "can't open backend log" << m_logFilePath;
    }
    appendLog(QStringLiteral("=== %1 starting backend (%2): %3")
                  .arg(QDateTime::currentDateTime().toString(Qt::ISODate), command.mode, command.display()));

    if (!command.ok()) {
        fail(Failure::FailedToStart, command.error, false);
        return;
    }

    m_token = protocol::generateToken();
    m_port = 0;
    m_stdoutBuf.clear();
    m_stderrBuf.clear();

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("QUICKSILVER_PORT"), QStringLiteral("0"));
    env.insert(QStringLiteral("QUICKSILVER_TOKEN"), m_token);
    env.remove(QStringLiteral("QUICKSILVER_EXIT_ON_STDIN_EOF")); // dev-only; never from the client
    for (auto it = m_extraEnv.constBegin(); it != m_extraEnv.constEnd(); ++it)
        env.insert(it.key(), it.value());

    m_process = new QProcess(this);
    m_process->setProgram(command.program);
    m_process->setArguments(command.arguments);
    m_process->setWorkingDirectory(command.workingDirectory);
    m_process->setProcessEnvironment(env);
    m_process->setProcessChannelMode(QProcess::SeparateChannels);

    m_stdin = std::make_unique<platform::ChildStdin>();
    if (!m_stdin->prepare(*m_process))
        qCWarning(lcBackend) << "couldn't create the stdin pipe; using QProcess's (exit on stdin close may not work)";

    m_job = std::make_unique<platform::ProcessJob>();
    m_jobActive = false;
    if (m_job->isValid())
        m_job->prepare(*m_process);
    else
        qCWarning(lcBackend) << "no job object:" << m_job->error();

    connect(m_process, &QProcess::started, this, &BackendProcess::onStarted);
    connect(m_process, &QProcess::readyReadStandardOutput, this, &BackendProcess::onStdout);
    connect(m_process, &QProcess::readyReadStandardError, this, &BackendProcess::onStderr);
    connect(m_process, &QProcess::finished, this, &BackendProcess::onFinished);
    connect(m_process, &QProcess::errorOccurred, this, &BackendProcess::onErrorOccurred);

    m_state = State::Starting;
    m_readyTimer.start(m_readyTimeoutMs);
    qCInfo(lcBackend) << "starting backend:" << command.display() << "in" << command.workingDirectory;
    // ReadWrite: keep stdin open; the backend exits when we close it.
    m_process->start(QIODevice::ReadWrite);
}

void BackendProcess::onStarted()
{
    const qint64 pid = m_process->processId();
    m_stdin->afterStart();
    if (m_job && m_job->isValid()) {
        m_jobActive = m_job->adopt(pid);
        if (!m_jobActive)
            qCWarning(lcBackend) << "could not put the backend in a job object:" << m_job->error();
    }
    qCInfo(lcBackend) << "backend started, pid" << pid << (m_jobActive ? "(in kill-on-close job)" : "");
}

void BackendProcess::onStdout()
{
    if (!m_process)
        return;
    m_stdoutBuf += m_process->readAllStandardOutput();
    qsizetype nl;
    while ((nl = m_stdoutBuf.indexOf('\n')) >= 0) {
        const QByteArray line = m_stdoutBuf.left(nl + 1);
        m_stdoutBuf.remove(0, nl + 1);
        handleStdoutLine(line);
    }
    if (m_stdoutBuf.size() > kMaxLineBytes) {
        handleStdoutLine(m_stdoutBuf);
        m_stdoutBuf.clear();
    }
}

void BackendProcess::handleStdoutLine(const QByteArray &line)
{
    if (m_state == State::Starting) {
        if (const auto readyInfo = protocol::parseReadyLine(line)) {
            if (readyInfo->protocolVersion != protocol::kProtocolVersion) {
                fail(Failure::VersionMismatch,
                     QStringLiteral("backend speaks protocol %1, this client speaks %2")
                         .arg(readyInfo->protocolVersion)
                         .arg(protocol::kProtocolVersion),
                     true);
                return;
            }
            m_readyTimer.stop();
            m_port = readyInfo->port;
            m_state = State::Ready;
            appendLog(QStringLiteral("[client] backend ready on port %1").arg(m_port));
            qCInfo(lcBackend) << "READY on port" << m_port;
            emit ready(m_port, m_token);
            return;
        }
    } else if (protocol::parseReadyLine(line)) {
        qCWarning(lcBackend) << "ignoring a second READY line";
    }
    // In dev, stdout can carry compile output; keep it in the log.
    const QString text = QString::fromUtf8(line).trimmed();
    if (!text.isEmpty())
        appendLog(QStringLiteral("[stdout] ") + text);
}

void BackendProcess::onStderr()
{
    if (!m_process)
        return;
    m_stderrBuf += m_process->readAllStandardError();
    qsizetype nl;
    while ((nl = m_stderrBuf.indexOf('\n')) >= 0) {
        QByteArray line = m_stderrBuf.left(nl);
        m_stderrBuf.remove(0, nl + 1);
        if (line.endsWith('\r'))
            line.chop(1);
        if (!line.trimmed().isEmpty()) // Logger pads entries with blank lines
            appendLog(QString::fromUtf8(line));
    }
    if (m_stderrBuf.size() > kMaxLineBytes) {
        appendLog(QString::fromUtf8(m_stderrBuf));
        m_stderrBuf.clear();
    }
}

void BackendProcess::onFinished(int exitCode, QProcess::ExitStatus status)
{
    if (m_state == State::Stopping || m_state == State::NotRunning)
        return;
    // Drain what's left before reporting.
    onStdout();
    onStderr();
    const QString detail = status == QProcess::CrashExit
                               ? QStringLiteral("the backend process crashed or was killed (exit code %1)").arg(exitCode)
                               : QStringLiteral("the backend process exited with code %1").arg(exitCode);
    fail(Failure::Exited, detail, false);
}

void BackendProcess::onErrorOccurred(QProcess::ProcessError error)
{
    if (error != QProcess::FailedToStart || m_state != State::Starting)
        return; // crashes arrive through finished()
    fail(Failure::FailedToStart,
         QStringLiteral("couldn't run %1: %2").arg(m_process->program(), m_process->errorString()), false);
}

void BackendProcess::onReadyTimeout()
{
    if (m_state != State::Starting)
        return;
    fail(Failure::ReadyTimeout,
         QStringLiteral("no READY line within %1 s").arg(m_readyTimeoutMs / 1000.0), true);
}

void BackendProcess::fail(Failure kind, const QString &detail, bool stopProcess)
{
    m_readyTimer.stop();
    appendLog(QStringLiteral("[client] backend failure: ") + detail);
    qCWarning(lcBackend) << "backend failure:" << kind << detail;
    if (stopProcess)
        stop(0);
    else
        teardown();
    emit failed(kind, detail);
}

void BackendProcess::stop(int graceMs)
{
    m_readyTimer.stop();
    if (!m_process) {
        teardown();
        return;
    }
    if (m_process->state() != QProcess::NotRunning) {
        m_state = State::Stopping;
        qCInfo(lcBackend) << "stopping backend: closing stdin, waiting up to" << graceMs << "ms";
        if (m_stdin)
            m_stdin->close(*m_process);
        else
            m_process->closeWriteChannel();
        if (graceMs <= 0 || !m_process->waitForFinished(graceMs)) {
            if (graceMs > 0)
                qCWarning(lcBackend) << "backend still running after" << graceMs << "ms; ending its job";
            if (m_job)
                m_job->terminate();
            m_process->kill();
            m_process->waitForFinished(2000);
        }
        // Collect any last output for the log.
        onStdout();
        onStderr();
        qCInfo(lcBackend) << "backend stopped, exit code" << m_process->exitCode();
        appendLog(QStringLiteral("[client] backend stopped"));
    }
    teardown();
}

void BackendProcess::teardown()
{
    if (m_process) {
        m_process->disconnect(this);
        m_process->deleteLater();
        m_process = nullptr;
    }
    m_stdin.reset();
    m_job.reset(); // closing the handle ends anything still in the job
    m_jobActive = false;
    m_state = State::NotRunning;
    m_port = 0;
}

} // namespace qs
