@echo off
REM ===========================================================================
REM sim\aliasgate\run_aliasgate_selftest.bat -- controls for the alias gate
REM
REM   NEG (must be RED)   : a COPY of board\wrapper_p4.v with the five TX
REM                         single-domain aliases restored to the pre-fix
REM                         (reversed) direction => the gate must exit 1 and
REM                         report rev=5 for APP_MODE-only while APP_MODE+
REM                         DP_156MHZ stays clean (the DP branch is a
REM                         different code path -- if it went red too, the
REM                         mutant would be wrong, not the gate).
REM   POS (must be GREEN) : the repository copy => exit 0, rev=0 in BOTH
REM                         configurations.  The repository file is never
REM                         touched: the mutant lives in _selftest\.
REM
REM   The assertions are in selftest_assert.py (python), not findstr/`find`:
REM   `find` is shadowed by MSYS's Unix find.exe when a .bat is invoked from
REM   this box's Git Bash (measured 2026-10-10) => it reads `/c` as a path and
REM   traverses the drive => the script HANGS.  findstr stays safe (Windows
REM   only, no MSYS twin), but exact counting is cleaner in python anyway.
REM
REM   exit: 0 = every control as expected, 1 = at least one control wrong.
REM   (A gate whose negative control cannot go red is a sieve, not a gate.)
REM ===========================================================================
setlocal
set "REPO_ROOT=%~dp0..\.."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [ALIASGATE SELFTEST FAIL] cannot locate this checkout from %~f0
  exit /b 1
)
set "PY=C:\Users\zhxue\anaconda3\python.exe"
if not exist "%PY%" set "PY="
if not defined PY for %%P in (python.exe) do if not defined PY set "PY=%%~$PATH:P"
if not defined PY (echo [ALIASGATE SELFTEST FAIL] no python found & exit /b 1)

set "WORK=%~dp0_selftest"
if not exist "%WORK%\" mkdir "%WORK%"
del /q "%WORK%\*_stdout.txt" >nul 2>&1

echo ==========================================================================
echo  alias gate self test -- NEG (mutant copy) / POS (repo copy)
echo ==========================================================================

echo.
echo ---- NEG: build the mutant copy, then run the gate on it ----
"%PY%" "%~dp0selftest_mutate.py" "%REPO_ROOT%\board\wrapper_p4.v" "%WORK%\wrapper_p4_mutant.v" > "%WORK%\mutate_stdout.txt" 2>&1
set "MRC=%ERRORLEVEL%"
type "%WORK%\mutate_stdout.txt"
if not "%MRC%"=="0" (
  echo [NEG] WRONG: mutant refused rc=%MRC% -- control NOT run
  echo ALIASGATE SELFTEST FAIL
  exit /b 1
)
"%PY%" "%~dp0alias_dir_check.py" --root "%REPO_ROOT%" --file "%WORK%\wrapper_p4_mutant.v" > "%WORK%\neg_stdout.txt" 2>&1
set "NRC=%ERRORLEVEL%"
type "%WORK%\neg_stdout.txt"

echo.
echo ---- POS: the repository copy must be clean ----
"%PY%" "%~dp0alias_dir_check.py" --root "%REPO_ROOT%" --file "%REPO_ROOT%\board\wrapper_p4.v" > "%WORK%\pos_stdout.txt" 2>&1
set "PRC=%ERRORLEVEL%"
type "%WORK%\pos_stdout.txt"

echo.
echo ---- assertions ----
"%PY%" "%~dp0selftest_assert.py" "%WORK%\neg_stdout.txt" "%NRC%" "%WORK%\pos_stdout.txt" "%PRC%"
set "ARC=%ERRORLEVEL%"
echo ==========================================================================
if not "%ARC%"=="0" (
  echo ALIASGATE SELFTEST FAIL -- at least one control behaved wrongly
  exit /b 1
)
echo ALIASGATE SELFTEST PASS -- negative control red, positive control green
echo ==========================================================================
exit /b 0
