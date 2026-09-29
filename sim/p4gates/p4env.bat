@echo off
REM ==========================================================================
REM sim\p4gates\p4env.bat -- environment for the P4 regression matrix gates.
REM
REM   SINGLE SOURCE OF TRUTH for the repository root.  Every gate .bat starts
REM   with:   call "%~dp0..\p4gates\p4env.bat" || exit /b 1
REM
REM   Nothing in this chain may hardcode a repository path.  REPO_ROOT is
REM   derived from THIS file's own location (%~dp0..\..), i.e. from the
REM   checkout the script physically lives in.  Rationale: the 2026-09 matrix
REM   runner hardcoded D:\repo\ECO\udp_hls_10g, so running it from this repo
REM   compiled ANOTHER checkout and still exited 0 (the "empty gate" defect:
REM   see P6B_INTEGRATION_REVIEW.md section 5).
REM
REM   P4_REPO_ROOT may override the derived root.  The override exists so the
REM   guard can be exercised with a deliberately wrong root (negative control);
REM   a root that does not contain this checkout is REFUSED here (p4gate.py
REM   guard), never silently used.
REM
REM   Exports: REPO_ROOT P4_SELF_ROOT P4GATE_DIR P4GATE_PY PATHS_TXT PY XV
REM            RTL TB BOARD TOOLS HLS GATES OUTDIR
REM   Optional (set by the runner): P4_WORKDIR  -- private cwd for one gate
REM ==========================================================================

set "P4GATE_DIR=%~dp0"
for %%I in ("%~dp0..\..") do set "P4_SELF_ROOT=%%~fI"
set "REPO_ROOT=%P4_SELF_ROOT%"
if defined P4_REPO_ROOT set "REPO_ROOT=%P4_REPO_ROOT%"
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
set "P4GATE_PY=%P4GATE_DIR%p4gate.py"
set "PATHS_TXT=%P4GATE_DIR%paths.txt"

if not exist "%P4GATE_PY%" (
  echo [P4GUARD FAIL] missing tool: %P4GATE_PY%
  exit /b 1
)
if not exist "%PATHS_TXT%" (
  echo [P4GUARD FAIL] missing path config: %PATHS_TXT%
  exit /b 1
)

REM ---- toolchain locations (from paths.txt; these are NOT repo paths) ----
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%PATHS_TXT%") do (
  if "%%a"=="PY" set "PY=%%b"
  if "%%a"=="XV" set "XV=%%b"
)
if not exist "%PY%" (
  echo [P4GUARD FAIL] python not found: %PY%
  exit /b 1
)
if not exist "%XV%\xvlog.bat" (
  echo [P4GUARD FAIL] xvlog not found: %XV%
  exit /b 1
)

REM ---- GUARD 1: the root must be THIS checkout ------------------------------
REM   Fails loudly and prints the actual path; never falls through to compiling
REM   whatever happens to be reachable.
"%PY%" "%P4GATE_PY%" guard --root "%REPO_ROOT%" --self-root "%P4_SELF_ROOT%" --self "%~f0"
if errorlevel 1 exit /b 1

REM ---- every repo-relative path, resolved against REPO_ROOT (one place) -----
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%PATHS_TXT%") do (
  if "%%a"=="RTL" set "RTL=%REPO_ROOT%\%%b"
  if "%%a"=="TB" set "TB=%REPO_ROOT%\%%b"
  if "%%a"=="BOARD" set "BOARD=%REPO_ROOT%\%%b"
  if "%%a"=="TOOLS" set "TOOLS=%REPO_ROOT%\%%b"
  if "%%a"=="HLS" set "HLS=%REPO_ROOT%\%%b"
  if "%%a"=="GATES" set "GATES=%REPO_ROOT%\%%b"
  if "%%a"=="OUTDIR" set "OUTDIR=%REPO_ROOT%\%%b"
)

REM ---- GUARD 2: the resolved directories must exist inside the root ---------
if not exist "%RTL%\" (
  echo [P4GUARD FAIL] RTL dir missing: %RTL%
  exit /b 1
)
if not exist "%TB%\" (
  echo [P4GUARD FAIL] TB dir missing: %TB%
  exit /b 1
)
if not exist "%TOOLS%\" (
  echo [P4GUARD FAIL] TOOLS dir missing: %TOOLS%
  exit /b 1
)
if not exist "%OUTDIR%\" (
  echo [P4GUARD FAIL] output dir missing: %OUTDIR%
  exit /b 1
)
exit /b 0
