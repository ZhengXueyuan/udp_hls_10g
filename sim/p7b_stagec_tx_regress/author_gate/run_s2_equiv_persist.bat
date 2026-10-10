@echo off
setlocal
REM =====================================================================
REM run_s2_equiv_persist.bat -- P7B-PERSIST S2 equivalence gate (design v3 7.2-S2)
REM   No simulator needed. Wrapper around s2_equiv_persist.py
REM   [L-A] anchor provenance: frozen/tcp_tx_frame_revcfd3b1a.v (LF-normalized)
REM         == git show cfd3b1a:rtl/tcp_tx_frame.v  (sha256)
REM   [L-B] L2 log pair: base/xs_runB_baseline.log vs ev/xs_runB_after.log --
REM         raw diff non-empty + every diff line is a designated metadata class
REM         + bodies byte-identical after dropping designated lines (sha256)
REM   --selfcheck: 3 negative controls (old 118KB anchor / other arm log / injected)
REM Exit code: 0 = all pass (incl. non-vacuity); 1 = fail
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "PY=C:\Users\zhxue\anaconda3\python.exe"
cd /d "%HERE%"
if not exist "%ROOT%\rtl\tcp_tx_frame.v" (echo [FAIL] RTL missing & exit /b 1)
"%PY%" s2_equiv_persist.py
set RC=%errorlevel%
echo.
echo ---- selfcheck (negative controls: must all have teeth) ----
"%PY%" s2_equiv_persist.py --selfcheck
set RC2=%errorlevel%
if not "%RC%"=="0" (echo S2_EQUIV: FAIL (formal) & exit /b 1)
if not "%RC2%"=="0" (echo S2_EQUIV: FAIL (selfcheck) & exit /b 1)
echo S2_EQUIV: PASS
exit /b 0
