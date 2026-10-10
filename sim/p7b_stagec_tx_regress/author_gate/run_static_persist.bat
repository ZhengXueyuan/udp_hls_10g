@echo off
setlocal
REM =====================================================================
REM run_static_persist.bat -- P7B-PERSIST static checks (S1 / FB / L1 / PD)
REM   No simulator needed. Wrapper around static_check_persist.py
REM   (pathguard + self-locate, same style as run_tx_ovl_gate.bat)
REM Exit code: 0 = all checks pass; 1 = at least one check failed.
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "PY=C:\Users\zhxue\anaconda3\python.exe"
cd /d "%HERE%"
if not exist "%ROOT%\rtl\tcp_tx_frame.v" (echo [FAIL] RTL missing & exit /b 1)
"%PY%" static_check_persist.py
set RC=%errorlevel%
echo.
echo ---- selfcheck (negative controls: must all have teeth) ----
"%PY%" static_check_persist.py --selfcheck
set RC2=%errorlevel%
if not "%RC%"=="0" (echo STATIC_PERSIST: FAIL (formal) & exit /b 1)
if not "%RC2%"=="0" (echo STATIC_PERSIST: FAIL (selfcheck) & exit /b 1)
echo STATIC_PERSIST: PASS
exit /b 0
