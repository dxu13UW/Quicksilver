// BackendLocator: which program starts the backend.
// Requirements: CON-1 (the client starts the backend). Also the LOG handoff
// rule: never launch the backend through a .bat via cmd.exe.

#include "core/backend_locator.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QTest>

using namespace qs;

namespace {
void touch(const QString &path)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    QVERIFY(f.open(QIODevice::WriteOnly));
}
} // namespace

class TestBackendLocator : public QObject {
    Q_OBJECT
private:
    QTemporaryDir m_tmp;
    QString m_erl, m_elixirBin, m_backend;

private slots:
    void initTestCase()
    {
        QVERIFY(m_tmp.isValid());
        // A fake Erlang + Elixir install and repo layout.
        m_erl = m_tmp.filePath("erl/bin/erl.exe");
        touch(m_erl);
        m_elixirBin = m_tmp.filePath("elixir/bin");
        touch(m_elixirBin + "/elixir.bat");
        touch(m_elixirBin + "/mix");
        QDir().mkpath(m_tmp.filePath("elixir/lib/elixir/ebin"));
        m_backend = m_tmp.filePath("repo/backend");
        touch(m_backend + "/mix.exs");
        QDir().mkpath(m_tmp.filePath("repo/frontend/build"));
    }

    QProcessEnvironment devEnv()
    {
        QProcessEnvironment env;
        env.insert("PATH", QDir::toNativeSeparators(QFileInfo(m_erl).absolutePath()) + QDir::listSeparator() +
                               QDir::toNativeSeparators(m_elixirBin));
        return env;
    }

    void dev_findsBackendUpwardFromExeDir()
    {
        const auto cmd = BackendLocator::resolve(devEnv(), m_tmp.filePath("repo/frontend/build"), {});
        QVERIFY2(cmd.ok(), qPrintable(cmd.error));
        QCOMPARE(cmd.mode, QStringLiteral("dev"));
        QCOMPARE(QFileInfo(cmd.program).fileName().toLower(), QStringLiteral("erl.exe"));
        QCOMPARE(QDir::cleanPath(cmd.workingDirectory), QDir::cleanPath(m_backend));
        // erl args mirror elixir.bat + backend/test/e2e/launch_e2e_test.exs.
        const QStringList a = cmd.arguments;
        QCOMPARE(a.first(), QStringLiteral("-noshell"));
        QVERIFY(a.contains("-elixir_root"));
        QCOMPARE(QDir::cleanPath(QDir::fromNativeSeparators(a[a.indexOf("-elixir_root") + 1])),
                 QDir::cleanPath(m_tmp.filePath("elixir/lib")));
        QCOMPARE(QDir::fromNativeSeparators(a[a.indexOf("-pa") + 1]),
                 QDir::cleanPath(m_tmp.filePath("elixir/lib/elixir/ebin")));
        const int s = a.indexOf("-s");
        QCOMPARE(a.mid(s, 3), (QStringList{"-s", "elixir", "start_cli"}));
        const int extra = a.indexOf("-extra");
        QVERIFY(extra > s);
        QCOMPARE(QDir::fromNativeSeparators(a[extra + 1]), QDir::cleanPath(m_tmp.filePath("elixir/bin/mix")));
        QCOMPARE(a.mid(extra + 2), (QStringList{"run", "--no-halt"}));
    }

    void dev_sourceDirFallback()
    {
        const auto cmd = BackendLocator::resolve(devEnv(), m_tmp.path(), m_tmp.filePath("repo/frontend"));
        QVERIFY2(cmd.ok(), qPrintable(cmd.error));
        QCOMPARE(QDir::cleanPath(cmd.workingDirectory), QDir::cleanPath(m_backend));
    }

    void dev_envOverrides()
    {
        QProcessEnvironment env; // empty PATH: everything from overrides
        env.insert("QUICKSILVER_BACKEND_DIR", m_backend);
        env.insert("QUICKSILVER_ERL", m_erl);
        env.insert("QUICKSILVER_ELIXIR_ROOT", m_tmp.filePath("elixir/lib"));
        const auto cmd = BackendLocator::resolve(env, {}, {});
        QVERIFY2(cmd.ok(), qPrintable(cmd.error));
        QCOMPARE(cmd.program, m_erl);
    }

    void dev_missingPieces()
    {
        QProcessEnvironment env;
        auto cmd = BackendLocator::resolve(env, {}, {});
        QVERIFY(!cmd.ok());
        QVERIFY(cmd.error.contains("backend"));

        env.insert("QUICKSILVER_BACKEND_DIR", m_backend);
        cmd = BackendLocator::resolve(env, {}, {});
        QVERIFY(!cmd.ok());
        QVERIFY(cmd.error.contains("erl.exe"));

        env.insert("QUICKSILVER_ERL", m_erl);
        cmd = BackendLocator::resolve(env, {}, {});
        QVERIFY(!cmd.ok());
        QVERIFY(cmd.error.contains("Elixir"));
    }

    void explicit_exe()
    {
        const QString exe = m_tmp.filePath("rel/bin/quicksilver_backend.exe");
        touch(exe);
        QProcessEnvironment env = devEnv();
        env.insert("QUICKSILVER_BACKEND_EXE", exe);
        env.insert("QUICKSILVER_BACKEND_ARGS", R"(start --flag "a b")");
        const auto cmd = BackendLocator::resolve(env, {}, {});
        QVERIFY2(cmd.ok(), qPrintable(cmd.error));
        QCOMPARE(cmd.mode, QStringLiteral("explicit"));
        QCOMPARE(cmd.program, exe);
        QCOMPARE(cmd.arguments, (QStringList{"start", "--flag", "a b"}));
        QCOMPARE(QDir::cleanPath(cmd.workingDirectory), QDir::cleanPath(m_tmp.filePath("rel/bin")));
    }

    void explicit_batchFileRejected_data()
    {
        QTest::addColumn<QString>("name");
        QTest::newRow("bat") << "quicksilver.bat";
        QTest::newRow("cmd") << "quicksilver.cmd";
        QTest::newRow("BAT upper") << "QUICKSILVER.BAT";
    }
    void explicit_batchFileRejected()
    {
        QFETCH(QString, name);
        const QString path = m_tmp.filePath("rel/bin/" + name);
        touch(path);
        QProcessEnvironment env;
        env.insert("QUICKSILVER_BACKEND_EXE", path);
        const auto cmd = BackendLocator::resolve(env, {}, {});
        QVERIFY(!cmd.ok());
        QVERIFY(cmd.error.contains("batch file"));
    }

    void explicit_missing()
    {
        QProcessEnvironment env;
        env.insert("QUICKSILVER_BACKEND_EXE", m_tmp.filePath("nope.exe"));
        const auto cmd = BackendLocator::resolve(env, {}, {});
        QVERIFY(!cmd.ok());
        QVERIFY(cmd.error.contains("not found"));
    }
};

QTEST_GUILESS_MAIN(TestBackendLocator)
#include "tst_backend_locator.moc"
