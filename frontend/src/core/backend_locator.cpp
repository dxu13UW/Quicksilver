#include "core/backend_locator.h"

#include <QDir>
#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>

namespace qs {

QString BackendCommand::display() const
{
    QStringList parts{QDir::toNativeSeparators(program)};
    for (const QString &a : arguments)
        parts << (a.contains(QLatin1Char(' ')) ? QStringLiteral("\"%1\"").arg(a) : a);
    return parts.join(QLatin1Char(' '));
}

bool BackendLocator::isBatchFile(const QString &program)
{
    const QString suffix = QFileInfo(program).suffix().toLower();
    return suffix == QLatin1String("bat") || suffix == QLatin1String("cmd");
}

QStringList BackendLocator::devErlArguments(const QString &elixirLib, const QStringList &mixArgs)
{
    const QString lib = QDir::cleanPath(elixirLib);
    const QString mixScript = QDir::cleanPath(lib + QStringLiteral("/../bin/mix"));
    QStringList args{
        QStringLiteral("-noshell"),
        QStringLiteral("-elixir_root"), QDir::toNativeSeparators(lib),
        QStringLiteral("-pa"), QDir::toNativeSeparators(lib + QStringLiteral("/elixir/ebin")),
        QStringLiteral("-s"), QStringLiteral("elixir"), QStringLiteral("start_cli"),
        QStringLiteral("-extra"), QDir::toNativeSeparators(mixScript),
    };
    args << mixArgs;
    return args;
}

namespace {

// Searches only the PATH of `env` (QStandardPaths::findExecutable would fall
// back to this process's PATH when the list is empty).
QString findOnPath(const QProcessEnvironment &env, const QString &name)
{
    const QStringList path = env.value(QStringLiteral("PATH")).split(QDir::listSeparator(), Qt::SkipEmptyParts);
    return path.isEmpty() ? QString() : QStandardPaths::findExecutable(name, path);
}

QString findBackendDir(const QString &appDir, const QString &sourceDir)
{
    QDir dir(appDir);
    for (int i = 0; i < 8 && !appDir.isEmpty(); ++i) {
        if (QFileInfo::exists(dir.filePath(QStringLiteral("backend/mix.exs"))))
            return dir.filePath(QStringLiteral("backend"));
        if (!dir.cdUp())
            break;
    }
    if (!sourceDir.isEmpty()) {
        const QString candidate = QDir::cleanPath(sourceDir + QStringLiteral("/../backend"));
        if (QFileInfo::exists(candidate + QStringLiteral("/mix.exs")))
            return candidate;
    }
    return {};
}

QString findElixirLib(const QProcessEnvironment &env)
{
    const QString fromEnv = env.value(QStringLiteral("QUICKSILVER_ELIXIR_ROOT"));
    if (!fromEnv.isEmpty())
        return fromEnv;
    for (const QString &name : {QStringLiteral("elixir.bat"), QStringLiteral("elixir")}) {
        const QString exe = findOnPath(env, name);
        if (!exe.isEmpty())
            return QDir::cleanPath(QFileInfo(exe).absolutePath() + QStringLiteral("/../lib"));
    }
    return {};
}

} // namespace

BackendCommand BackendLocator::resolve(const QProcessEnvironment &env, const QString &appDir,
                                       const QString &sourceDir)
{
    BackendCommand cmd;

    const QString explicitExe = env.value(QStringLiteral("QUICKSILVER_BACKEND_EXE"));
    if (!explicitExe.isEmpty()) {
        cmd.mode = QStringLiteral("explicit");
        cmd.program = explicitExe;
        cmd.arguments = QProcess::splitCommand(env.value(QStringLiteral("QUICKSILVER_BACKEND_ARGS")));
        cmd.workingDirectory = env.value(QStringLiteral("QUICKSILVER_BACKEND_DIR"));
        if (cmd.workingDirectory.isEmpty())
            cmd.workingDirectory = QFileInfo(explicitExe).absolutePath();
        if (isBatchFile(explicitExe))
            cmd.error = QStringLiteral("QUICKSILVER_BACKEND_EXE points at a batch file (%1). "
                                       "Batch files run through cmd.exe, which breaks the backend's pipes; "
                                       "point it at an .exe instead.")
                            .arg(QDir::toNativeSeparators(explicitExe));
        else if (!QFileInfo(explicitExe).isFile())
            cmd.error = QStringLiteral("QUICKSILVER_BACKEND_EXE not found: %1")
                            .arg(QDir::toNativeSeparators(explicitExe));
        return cmd;
    }

    cmd.mode = QStringLiteral("dev");
    QString backendDir = env.value(QStringLiteral("QUICKSILVER_BACKEND_DIR"));
    if (backendDir.isEmpty())
        backendDir = findBackendDir(appDir, sourceDir);
    if (backendDir.isEmpty() || !QFileInfo::exists(backendDir + QStringLiteral("/mix.exs"))) {
        cmd.error = QStringLiteral("Can't find the backend. Set QUICKSILVER_BACKEND_DIR to the backend folder "
                                   "(the one with mix.exs), or QUICKSILVER_BACKEND_EXE to a backend executable.");
        return cmd;
    }
    cmd.workingDirectory = QDir::cleanPath(backendDir);

    QString erl = env.value(QStringLiteral("QUICKSILVER_ERL"));
    if (erl.isEmpty())
        erl = findOnPath(env, QStringLiteral("erl"));
    if (erl.isEmpty() || isBatchFile(erl)) {
        cmd.error = QStringLiteral("Can't find erl.exe (Erlang/OTP). Put it on PATH or set QUICKSILVER_ERL.");
        return cmd;
    }

    const QString elixirLib = findElixirLib(env);
    if (elixirLib.isEmpty() || !QFileInfo::exists(elixirLib + QStringLiteral("/elixir/ebin"))) {
        cmd.error = QStringLiteral("Can't find Elixir. Put elixir on PATH or set QUICKSILVER_ELIXIR_ROOT "
                                   "to Elixir's lib folder.");
        return cmd;
    }

    cmd.program = erl;
    cmd.arguments = devErlArguments(elixirLib, {QStringLiteral("run"), QStringLiteral("--no-halt")});
    return cmd;
}

} // namespace qs
