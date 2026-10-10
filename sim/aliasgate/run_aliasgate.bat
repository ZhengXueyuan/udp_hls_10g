@echo off
REM ===========================================================================
REM sim\aliasgate\run_aliasgate.bat -- STANDING alias-direction gate (2026-10-10)
REM
REM   Face: a pure-text port-direction trace of `assign X = Y;` aliases in
REM   board\wrapper_p4.v, for BOTH live macro configurations
REM   (APP_MODE-only  and  APP_MODE+DP_156MHZ).
REM
REM   Why it exists: the 2026-10-10 p5_wrapper red was board\wrapper_p4.v:2771-
REM   2775 with all five aliases REVERSED => m_tx_tvalid / txsrc_tready left
REM   undriven (Z) => TX dead in that config.  Vivado 2025.2 prints nothing for
REM   an undriven net, and run_lint_p6e.bat's macro set compiles exactly the
REM   buggy branch and still says LINT-OK (measured) -- so this is a NEW face,
REM   not a new key on an existing one.
REM
REM   Criterion, coverage boundary, self-trust instrument: see the header of
REM   sim\aliasgate\alias_dir_check.py.  Evidence: the report in
REM   _proj_10g\notes\p7b_aliasgate_20261010\ (+ run_aliasgate_selftest.bat).
REM
REM   exit: 0 = clean, 1 = reversed/multi-driven alias (or parser selfcheck
REM         failed), 2 = refused (path guard / missing tool).
REM
REM   optional arg %1 = target file (default board\wrapper_p4.v).  It exists so
REM   a control run can point the SAME gate at a mutant copy; the lint entry
REM   passes nothing, so the standing gate always checks the live wrapper.  The
REM   target it actually checked is always echoed (a silently retargeted gate
REM   would be an "empty gate").
REM ===========================================================================
setlocal
set "REPO_ROOT=%~dp0..\.."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [ALIASGATE FAIL] cannot locate this checkout from %~f0
  exit /b 2
)
set "PY=C:\Users\zhxue\anaconda3\python.exe"
if not exist "%PY%" set "PY="
if not defined PY for %%P in (python.exe) do if not defined PY set "PY=%%~$PATH:P"
if not defined PY (echo [ALIASGATE FAIL] no python interpreter found & exit /b 2)

REM --- pathguard tripwire (same convention as every gate in this repo) ------
if exist "%REPO_ROOT%\sim\p4gates\p4gate.py" (
  "%PY%" "%REPO_ROOT%\sim\p4gates\p4gate.py" selfcheck --root "%REPO_ROOT%" --bat "%~f0" --quiet || exit /b 2
)

set "TARGET=%REPO_ROOT%\board\wrapper_p4.v"
if not "%~1"=="" set "TARGET=%~f1"
echo ALIASGATE target = %TARGET%
"%PY%" "%REPO_ROOT%\sim\aliasgate\alias_dir_check.py" --root "%REPO_ROOT%" --file "%TARGET%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo ALIASGATE FAIL rc=%RC%
) else (
  echo ALIASGATE OK
)
exit /b %RC%
