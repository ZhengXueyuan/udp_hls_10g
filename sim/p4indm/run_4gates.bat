@echo off
REM ==========================================================================
REM sim\p4indm\run_4gates.bat -- re-run the 4 P4 gates that an earlier taskkill
REM   interrupted: pcackoob / vlanchain / vlanburst / stallgate.
REM
REM   Those 4 are 4 of the 16 gates declared by
REM   sim\p4gates\run_matrix_p4dfix.bat, so this entry DELEGATES to that runner
REM   with -only instead of carrying a second copy of the compile sets.  The
REM   delegated run inherits the runner's guards (checkpaths / manifestcheck /
REM   scanlog / revision fingerprint) and its exit codes.
REM
REM   history: until 2026-09-30 this gate was sim\p4indm\run_4gates.sh and used
REM   cmd syntax (%REPO_ROOT%) inside a bash script -- under bash the variable
REM   never expands, every path became the literal string "%REPO_ROOT%", no
REM   gate ran and the script still reported success.  Its .sh sibling is now a
REM   thin shim onto this file.
REM
REM   usage: cmd //c 'sim\p4indm\run_4gates.bat'
REM   exit : 0 all 4 pass / 1 a gate failed / 2 revision drift / 97 refusal
REM ==========================================================================
setlocal
set "REPO_ROOT=%~dp0..\.."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)
set "RUNNER=%REPO_ROOT%\sim\p4gates\run_matrix_p4dfix.bat"
if not exist "%RUNNER%" (
  echo [PATHGUARD FAIL] matrix runner not found: %RUNNER%
  exit /b 1
)
call "%RUNNER%" -only pcackoob+vlanchain+vlanburst+stallgate
set "RC=%errorlevel%"
echo [P4INDM 4GATES] gate=pcackoob+vlanchain+vlanburst+stallgate exit=%RC%
exit /b %RC%
