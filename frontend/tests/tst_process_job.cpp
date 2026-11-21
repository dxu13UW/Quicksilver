// platform::ProcessJob: closing the job ends the child and its children.
// Requirements: CON-1 (no backend process left behind, even if the client
// crashes: the OS closes our job handle then).

#include "platform/child_stdin.h"
#include "platform/process_job.h"

#include <QProcess>
#include <QTest>

#ifdef Q_OS_WIN
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#endif

using qs::platform::ProcessJob;

class TestProcessJob : public QObject {
    Q_OBJECT
private slots:
    void initTestCase()
    {
#ifndef Q_OS_WIN
        QSKIP("Job Objects are Windows-only");
#endif
    }

#ifdef Q_OS_WIN
    static QString system32(const char *exe)
    {
        wchar_t dir[MAX_PATH];
        GetSystemDirectoryW(dir, MAX_PATH);
        return QString::fromWCharArray(dir) + QLatin1Char('\\') + QLatin1String(exe);
    }

    static QList<DWORD> childrenOf(DWORD pid)
    {
        QList<DWORD> out;
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        PROCESSENTRY32W pe{};
        pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) {
            do {
                if (pe.th32ParentProcessID == pid)
                    out << pe.th32ProcessID;
            } while (Process32NextW(snap, &pe));
        }
        CloseHandle(snap);
        return out;
    }

    void childIsResumedAndRuns()
    {
        ProcessJob job;
        QVERIFY2(job.isValid(), qPrintable(job.error()));
        QProcess p;
        job.prepare(p);
        bool adopted = false;
        connect(&p, &QProcess::started, this, [&] { adopted = job.adopt(p.processId()); });
        p.start(system32("ping.exe"), {"-n", "1", "127.0.0.1"});
        QVERIFY(p.waitForStarted(5000));
        QVERIFY2(adopted, qPrintable(job.error()));
        // It was created suspended; it only finishes if adopt() resumed it.
        QVERIFY(p.waitForFinished(10000));
        QCOMPARE(p.exitStatus(), QProcess::NormalExit);
        QVERIFY(p.readAllStandardOutput().contains("127.0.0.1"));
    }

    void closingJob_killsChildAndGrandchild()
    {
        auto job = std::make_unique<ProcessJob>();
        QProcess p;
        job->prepare(p);
        connect(&p, &QProcess::started, this, [&] { QVERIFY(job->adopt(p.processId())); });
        // cmd starts ping as a grandchild of this test. /d skips AutoRun.
        p.start(system32("cmd.exe"), {"/d", "/c", system32("ping.exe") + " -n 60 127.0.0.1 >nul"});
        QVERIFY(p.waitForStarted(5000));
        const DWORD cmdPid = DWORD(p.processId());

        QList<DWORD> kids;
        QTRY_VERIFY_WITH_TIMEOUT(!(kids = childrenOf(cmdPid)).isEmpty(), 5000);
        HANDLE grandchild = OpenProcess(SYNCHRONIZE, FALSE, kids.first());
        QVERIFY(grandchild);
        QVERIFY(!p.waitForFinished(300)); // still running

        job.reset(); // like the client crashing: the handle closes

        QVERIFY(p.waitForFinished(5000));
        QCOMPARE(WaitForSingleObject(grandchild, 5000), DWORD(WAIT_OBJECT_0));
        CloseHandle(grandchild);
    }

    // ChildStdin + ProcessJob chained: closing our end is EOF for the child.
    // sort.exe reads stdin to EOF, then exits.
    void childStdin_closeIsEof_data()
    {
        QTest::addColumn<bool>("stdinFirst");
        QTest::newRow("stdin then job") << true;
        QTest::newRow("job then stdin") << false;
    }
    void childStdin_closeIsEof()
    {
        QFETCH(bool, stdinFirst);
        ProcessJob job;
        qs::platform::ChildStdin in;
        QProcess p;
        if (stdinFirst) {
            QVERIFY(in.prepare(p));
            job.prepare(p);
        } else {
            job.prepare(p);
            QVERIFY(in.prepare(p));
        }
        connect(&p, &QProcess::started, this, [&] {
            in.afterStart();
            QVERIFY(job.adopt(p.processId()));
        });
        p.start(system32("sort.exe"), {}, QIODevice::ReadOnly);
        QVERIFY(p.waitForStarted(5000));
        QVERIFY(!p.waitForFinished(500)); // waiting on stdin
        in.close(p);
        QVERIFY(p.waitForFinished(5000));
        QCOMPARE(p.exitCode(), 0);
    }

    void terminate_endsJobNow()
    {
        ProcessJob job;
        QProcess p;
        job.prepare(p);
        connect(&p, &QProcess::started, this, [&] { QVERIFY(job.adopt(p.processId())); });
        p.start(system32("ping.exe"), {"-n", "60", "127.0.0.1"});
        QVERIFY(p.waitForStarted(5000));
        job.terminate(7);
        QVERIFY(p.waitForFinished(5000));
        QCOMPARE(p.exitCode(), 7);
    }
#endif
};

QTEST_GUILESS_MAIN(TestProcessJob)
#include "tst_process_job.moc"
