@echo off
rem One-command build for the Qt client: configure, build, and run the tests.
rem   build.bat            Debug build + all tests
rem   build.bat clean      delete build\ first
rem   build.bat notest     build only
rem Override the Qt location with QT_DIR (default C:\Qt\6.8.3\msvc2022_64).
setlocal
if "%QT_DIR%"=="" set "QT_DIR=C:\Qt\6.8.3\msvc2022_64"
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

call "%VCVARS%" >nul || exit /b 1
cd /d "%~dp0"

if /i "%~1"=="clean" (
  if exist build rmdir /s /q build
)

cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug "-DCMAKE_PREFIX_PATH=%QT_DIR%" || exit /b 1
cmake --build build || exit /b 1

if /i "%~1"=="notest" exit /b 0
if /i "%~2"=="notest" exit /b 0
ctest --test-dir build --output-on-failure || exit /b 1
exit /b 0
