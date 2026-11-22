@echo off
rem One-command build for the Qt client: configure, build, and run the tests.
rem   build.bat            Debug build + all tests
rem   build.bat clean      delete build\ first
rem   build.bat notest     build only
rem Override the Qt location with QT_DIR (default C:\Qt\6.8.3\msvc2022_64).
rem Override the build folder with QS_BUILD_DIR (default build), e.g. while a
rem Quicksilver.exe started from build\ is still running and locks its files.
setlocal
if "%QT_DIR%"=="" set "QT_DIR=C:\Qt\6.8.3\msvc2022_64"
if "%QS_BUILD_DIR%"=="" set "QS_BUILD_DIR=build"
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

call "%VCVARS%" >nul || exit /b 1
cd /d "%~dp0"

if /i "%~1"=="clean" (
  if exist "%QS_BUILD_DIR%" rmdir /s /q "%QS_BUILD_DIR%"
)

cmake -S . -B "%QS_BUILD_DIR%" -G Ninja -DCMAKE_BUILD_TYPE=Debug "-DCMAKE_PREFIX_PATH=%QT_DIR%" || exit /b 1
cmake --build "%QS_BUILD_DIR%" || exit /b 1

if /i "%~1"=="notest" exit /b 0
if /i "%~2"=="notest" exit /b 0
ctest --test-dir "%QS_BUILD_DIR%" --output-on-failure || exit /b 1
exit /b 0
