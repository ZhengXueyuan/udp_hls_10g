@echo off
set "REPO_ROOT=%~dp0..\..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

rem ===================================================================
rem build_udpsend.bat -- build udpsend.exe with MinGW-w64 g++
rem
rem GOTCHA (same as build.bat): mingw64\bin MUST be on PATH, otherwise
rem cc1.exe silently fails to start (exit code 1, zero output).
rem ===================================================================
set PATH=C:\msys64\mingw64\bin;%PATH%
cd /d %REPO_ROOT%\tools\cpp_peer
call g++.exe -O2 -std=c++17 -o udpsend.exe udpsend.cpp -lws2_32
if errorlevel 1 (echo BUILD_FAILED & exit /b 1)
findstr /C:"BUILD" NUL >NUL 2>NUL
echo BUILD_OK
exit /b 0
