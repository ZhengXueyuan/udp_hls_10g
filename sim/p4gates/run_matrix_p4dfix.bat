@echo off
REM ==========================================================================
REM sim\p4gates\run_matrix_p4dfix.bat
REM   P4 DEFAULT-BUILD REGRESSION MATRIX (16 gates) -- Windows-side runner.
REM
REM   usage:  cmd //c 'sim\p4gates\run_matrix_p4dfix.bat' [/canonical]
REM           cmd //c 'sim\p4gates\run_matrix_p4dfix.bat' /only chain+unit_vlan
REM   NOTE: the /only separator is '+' -- cmd splits ',' and ';' as token
REM   separators, so a comma separated list cannot survive the command line.
REM   From git bash use the shim sim/p4sim/run_matrix_p4dfix.sh -- it disables
REM   MSYS argument path conversion (otherwise /only becomes C:/Program Files/...) .
REM   git-bash entry point (unchanged for callers):
REM     bash sim/p4sim/run_matrix_p4dfix.sh          <- self-locating shim
REM
REM   Per gate:
REM     1. every path is resolved from REPO_ROOT, which is derived from this
REM        file's own location (sim\p4gates\p4env.bat) -- no repository path
REM        literal exists anywhere in the chain any more;
REM     2. pre-flight guard: checkpaths (manifest + bat + cwd must be INSIDE
REM        the repo and must exist) + manifestcheck (the declared file list
REM        must equal the list literally present in the gate .bat);
REM     3. run the gate in a PRIVATE cwd (sim\p4gates\work_<stamp>\<gate>) so
REM        xsim.dir locks and stale .memh files cannot cross-contaminate;
REM     4. post-flight guard: scanlog -- every absolute path in this gate's
REM        logs must be inside the repo (a foreign path = FAIL, not silence).
REM
REM   The matrix log header carries a revision fingerprint (path + SHA256 of
REM   the whole compile set, git HEAD, tracked-modified list).  A second
REM   fingerprint is taken at the end; if anything changed while the matrix ran
REM   the runner exits 2 and reports DRIFT -- the per-gate results are then not
REM   bound to any single revision.  /canonical runs the gates in their
REM   historical directories instead (refused while another xsim.exe runs).
REM
REM   exit codes: 0 ok, 1 a gate failed, 2 revision drift, 97 precheck refusal.
REM ==========================================================================
setlocal EnableDelayedExpansion

REM capture the script name BEFORE the arg loop (shift moves %0 as well)
set "RUNNER_NAME=%~nx0"

call "%~dp0p4env.bat"
if errorlevel 1 exit /b 1

for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%PATHS_TXT%") do (
  if "%%a"=="MATRIX_LOG" set "MATRIX_LOG_NAME=%%b"
)
set "MATRIX_LOG=%OUTDIR%\%MATRIX_LOG_NAME%"
set "FRAME_FIFO=%RTL%\frame_fifo.v"

REM ---- arguments: [/isolated|/canonical] [/only gate1,gate2,...] -----------
set "MODE=isolated"
set "GATE_ONLY="
:argloop
if "%~1"=="" goto :args_done
if /i "%~1"=="/canonical" set "MODE=canonical"
if /i "%~1"=="-canonical" set "MODE=canonical"
if /i "%~1"=="/isolated" set "MODE=isolated"
if /i "%~1"=="-isolated" set "MODE=isolated"
if /i "%~1"=="/only" set "GATE_ONLY=%~2"
if /i "%~1"=="-only" set "GATE_ONLY=%~2"
shift
goto :argloop
:args_done
REM cmd treats ',' and ';' as token separators, so a comma separated list can
REM never arrive intact: the documented separator is '+'; ',' is normalised.
if defined GATE_ONLY set "GATE_ONLY=%GATE_ONLY:,=+%"

if /i not "%MODE%"=="canonical" goto :mode_done
tasklist /fi "imagename eq xsim.exe" 2>nul | findstr /i "xsim.exe" >nul
if errorlevel 1 goto :mode_done
echo [P4GUARD NOTE] another xsim.exe is running -- /canonical refused, using a private work dir
set "MODE=isolated"

:mode_done
set "ISOLATED="
if /i "%MODE%"=="isolated" set "ISOLATED=1"

"%PY%" "%P4GATE_PY%" stamp > "%OUTDIR%\_p4stamp.txt" 2>nul
set "STAMP="
for /f "usebackq delims=" %%t in ("%OUTDIR%\_p4stamp.txt") do set "STAMP=%%t"
del /q "%OUTDIR%\_p4stamp.txt" >nul 2>&1
if not defined STAMP set "STAMP=nostamp"
set "WORKROOT=%GATES%\work_%STAMP%"
if defined ISOLATED if not exist "%WORKROOT%\" mkdir "%WORKROOT%"
set "FP_BEFORE=%OUTDIR%\P4_MATRIX_FINGERPRINT_%STAMP%_before.txt"
set "FP_AFTER=%OUTDIR%\P4_MATRIX_FINGERPRINT_%STAMP%_after.txt"

set "GATE_FAIL=0"
set "GATE_RUN=0"
set "DRIFT=0"

>"%MATRIX_LOG%" echo ==== P4 DEFAULT-BUILD REGRESSION MATRIX (16 gates) ====
call :log "started     : %DATE% %TIME%"
call :log "repo root   : %REPO_ROOT%"
call :log "root source : %P4_SELF_ROOT%  (derived from this script's own location)"
call :log "run mode    : %MODE%"
call :log "work root   : %WORKROOT%"
call :log "matrix log  : %MATRIX_LOG%"
call :log "gate list   : the 16 'call :gate' rows in %RUNNER_NAME% (declared once)"
set "GATE_FILTER=%GATE_ONLY%"
if "%GATE_ONLY%"=="" set "GATE_FILTER=(none -- all 16)"
call :log "gate filter : %GATE_FILTER%"
call :log "guard       : checkpaths + manifestcheck before, scanlog after each gate"
call :log "note        : gates unit_retx / unit_fifo exit 0 unconditionally (their"
call :log "              .bat ends in 'type xsim*.log') -- read their console tail."

call :log "--- revision fingerprint (before) ---"
"%PY%" "%P4GATE_PY%" fingerprint --root "%REPO_ROOT%" --out "%FP_BEFORE%" --label before >>"%MATRIX_LOG%" 2>&1
if errorlevel 1 goto :fatal_fp

call :log "--- gates ---"
call :gate chain       sim\p4sim\run_tb_p4_chain.bat       chain_src.f -                           -
call :gate burst200    sim\p4sim\run_tb_p4_burst.bat       chain_src.f -                           "200"
call :gate trunc50     sim\p4sim\run_tb_p4_burst.bat       chain_src.f "TRUNC=50;TRUNCM=8"          "200"
call :gate trunc100    sim\p4sim\run_tb_p4_burst.bat       chain_src.f "TRUNC=100;TRUNCM=8"         "200"
call :gate halfdrop    sim\p4sim\run_tb_p4_burst.bat       chain_src.f "HALFDROP=100;HALFDROPK=990" "200"
call :gate txdrop50    sim\p4sim\run_tb_p4_burst.bat       chain_src.f -                           "200 -1 0 4000 0 0 50"
call :gate gate4096    sim\p4sim\run_tb_p4_burst.bat       chain_src.f -                           "200 -1 0 10"
call :gate dupstorm    sim\p4sim\run_tb_p4_burst.bat       chain_src.f -                           "200 0 0 4000 608 dup"
call :gate pcackoob    sim\p4sim\run_tb_p4_burst.bat       chain_src.f "PCACKOOB=1"                "200"
call :gate vlanchain   sim\p4sim\run_tb_p4_chain_vlan.bat  chain_src.f -                           -
call :gate vlanburst   sim\p4sim\run_tb_p4_burst_vlan.bat  chain_src.f -                           "200"
call :gate stallgate   sim\p4sim\run_tb_p4_chain_stall.bat chain_src.f -                           -
call :gate unit_retx   sim\retxsim\run_retx_tb.bat         retx_src.f  -                           -
call :gate unit_fifo   sim\retxsim2\run_tb_frame_fifo.bat  fifo_src.f  -                           "%FRAME_FIFO%"
call :gate unit_vlan   sim\vlansim\run_tb_vlan_strip.bat   vlan_src.f  -                           -
call :gate unit_uart   sim\tbgate\run_tb_uart_dbg.bat      uart_src.f  -                           -

call :log "--- revision fingerprint (after) ---"
"%PY%" "%P4GATE_PY%" fingerprint --root "%REPO_ROOT%" --out "%FP_AFTER%" --label after >>"%MATRIX_LOG%" 2>&1
if errorlevel 1 goto :fatal_fp2

call :log "--- freeze check ---"
"%PY%" "%P4GATE_PY%" compare --a "%FP_BEFORE%" --b "%FP_AFTER%" >>"%MATRIX_LOG%" 2>&1
if errorlevel 1 set "DRIFT=1"

call :log "--- summary ---"
call :log "gate filter : %GATE_FILTER%"
call :log "gates run   : %GATE_RUN% / 16"
call :log "gates failed: %GATE_FAIL%"
call :log "MATRIX DONE %DATE% %TIME%"
echo ---- summary ----
findstr /b "GATE " "%MATRIX_LOG%"

if not "%DRIFT%"=="0" (
  echo [P4GUARD FAIL] REVISION DRIFT: sources changed while the matrix ran
  exit /b 2
)
if not "%GATE_FAIL%"=="0" exit /b 1
exit /b 0

REM --------------------------------------------------------------------------
:fatal_fp
call :log "FATAL: pre-run fingerprint failed -- nothing was tested"
echo [P4GATE FATAL] pre-run fingerprint failed -- nothing was tested
exit /b 1
:fatal_fp2
call :log "FATAL: post-run fingerprint failed"
echo [P4GATE FATAL] post-run fingerprint failed
exit /b 1

REM --------------------------------------------------------------------------
:gate
REM %1=name %2=bat(repo-rel) %3=manifest %4=env(VAR=VAL;...) or - %5=args or -
set "GN=%~1"
set "GBAT=%REPO_ROOT%\%~2"
set "GMAN=%GATES%\%~3"
set "GENV=%~4"
set "GARGS=%~5"
if "%GENV%"=="-" set "GENV="
if "%GARGS%"=="-" set "GARGS="
for %%D in ("%GBAT%") do set "GDIR=%%~dpD"

REM optional gate selection: /only a,b,c  (exact name match)
if "%GATE_ONLY%"=="" goto :gate_sel_done
echo +%GATE_ONLY%+ | findstr /i /c:"+%GN%+" >nul
if errorlevel 1 (
  echo GATE %GN% SKIPPED -- not selected by /only %GATE_ONLY%
  exit /b 0
)
:gate_sel_done

REM every stimulus env var any P4 gate reads -- cleared, then this gate's own
set "TRUNC="
set "TRUNCM="
set "HALFDROP="
set "HALFDROPK="
set "PCACKOOB="
set "P4_WORKDIR="
REM NB: no inline 'if ... for %%V in ()' -- cmd parses the whole line first and an
REM empty for-set is a syntax error even when the 'if' is false.
if "%GENV%"=="" goto :gate_env_done
for %%V in (%GENV:;= %) do set "%%V"
:gate_env_done

set "GWORK=%GDIR%"
if defined ISOLATED set "GWORK=%WORKROOT%\%GN%"
if not exist "%GWORK%\" mkdir "%GWORK%"
set "P4_WORKDIR=%GWORK%"
set "GLOG=%GWORK%\_gate_console.log"
set /a GATE_RUN=GATE_RUN+1

call :log "=== GATE %GN% : %~2 %GARGS%   [env %GENV%]   [cwd %GWORK%]"

set "PRECHK=ok"
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --manifest "%GMAN%" --path "%GBAT%" --path "%GWORK%" >>"%MATRIX_LOG%" 2>&1
if errorlevel 1 set "PRECHK=checkpaths"
"%PY%" "%P4GATE_PY%" manifestcheck --root "%REPO_ROOT%" --manifest "%GMAN%" --bat "%GBAT%" >>"%MATRIX_LOG%" 2>&1
if errorlevel 1 if "%PRECHK%"=="ok" set "PRECHK=manifestcheck"

set "RC=0"
if not "%PRECHK%"=="ok" (
  call :log "PRECHECK-FAIL %GN% [%PRECHK%] -- gate NOT run"
  set "RC=97"
) else (
  pushd "%GWORK%"
  call "%GBAT%" %GARGS% > "%GLOG%" 2>&1
  set "RC=!errorlevel!"
  popd
)

"%PY%" "%P4GATE_PY%" scanlog --root "%REPO_ROOT%" --logdir "%GWORK%" >>"%MATRIX_LOG%" 2>&1
if errorlevel 1 if "%RC%"=="0" set "RC=98"

call :log "EXIT=%RC%"
REM gatebrief prints to stdout; the runner's own >> does the appending (a
REM second writer would get PermissionError on the open matrix log)
"%PY%" "%P4GATE_PY%" gatebrief --log "%GLOG%" --lines 6 >>"%MATRIX_LOG%" 2>&1
call :log "---"
if not "%RC%"=="0" set /a GATE_FAIL=GATE_FAIL+1
echo GATE %GN% EXIT=%RC%
REM let file handles / xsim.dir locks settle before the next gate
ping -n 4 127.0.0.1 >nul
exit /b 0

:log
>>"%MATRIX_LOG%" echo %~1
exit /b 0
