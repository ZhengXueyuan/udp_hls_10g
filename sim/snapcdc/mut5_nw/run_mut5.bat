@echo off
REM ---------------------------------------------------------------------------
REM run_mut5.bat -- mutation / control runs for the snap_cdc gate.
REM   usage: run_mut5.bat null | nolatch | nwbug        (default: null)
REM
REM   Every config runs the SAME 5 widths as sim/snapcdc/run_tb_snap_cdc.bat
REM   (14/22/24/32/36) and compares each width's verdict against the EXPECTED one:
REM
REM     null    : DUT = rtl/snap_cdc.v (verbatim) + TB = tb/tb_snap_cdc.v
REM               expected PASS_ALL at ALL 5 widths.
REM               A/A control: proves this runner does not just fail everything,
REM               and that the 5 widths are 5 real runs (each re-elaborates and
REM               re-simulates -- the TB echoes the NW it really compiled).
REM     nolatch : DUT = snap_cdc_mut_nolatch.v (the hold_b latch removed,
REM               dout_a <= din_b) + the real TB
REM               expected FAIL at ALL 5 widths.  Includes the two REAL bundle
REM               widths 14 (SNAP_FE_NW) and 22 (SNAP_DP_NW): the criteria bite there
REM               too, not only at the historical 24/32.
REM     nwbug   : DUT = real rtl + TB = tb_snap_cdc_nwbug.v (the `elsif TB_NW_36
REM               branch deleted, so the TB silently falls back to NW=32)
REM               expected FAIL at NW=36 ONLY.  Faithful reproduction of the defect
REM               this revision fixes ("runner echoes 36, the run is really 32") --
REM               and the other four widths must still PASS, which is exactly what
REM               proves the new width assertion is checked PER RUN.
REM
REM   All the hard-fail rules of the real gate are kept identical here (implicit
REM   nets, VRFC 10-3091, TB_NW_SEL width assertion, SKEW_SELFTEST, PASS_ALL).
REM   Nothing is weakened for the mutants.
REM
REM   exit 0 = every width behaved as expected / 1 = otherwise.
REM   bat rules: ASCII only + CRLF.
REM ---------------------------------------------------------------------------
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set CFG=%1
if "%CFG%"=="" set CFG=null
if /i not "%CFG%"=="null" if /i not "%CFG%"=="nolatch" if /i not "%CFG%"=="nwbug" (echo MUT-UNKNOWN-CFG: %CFG% & exit /b 1)
set DUT=%ROOT%\rtl\snap_cdc.v
set TB=%ROOT%\tb\tb_snap_cdc.v
if /i "%CFG%"=="nolatch" set DUT=%~dp0snap_cdc_mut_nolatch.v
if /i "%CFG%"=="nwbug"   set TB=%~dp0tb_snap_cdc_nwbug.v
if not exist "%DUT%" (echo MUT-DUT-MISSING: %DUT% & exit /b 1)
if not exist "%TB%"  (echo MUT-TB-MISSING: %TB% & exit /b 1)
echo ================= snap_cdc mutation run: cfg=%CFG% =================
echo   DUT = %DUT%
echo   TB  = %TB%
certutil -hashfile "%DUT%" SHA256 > "%~dp0fingerprint_%CFG%.txt"
certutil -hashfile "%TB%" SHA256 >> "%~dp0fingerprint_%CFG%.txt"
echo run at %DATE% %TIME% >> "%~dp0fingerprint_%CFG%.txt"
set BAD=0
call :one 14
if errorlevel 1 set BAD=1
call :one 22
if errorlevel 1 set BAD=1
call :one 24
if errorlevel 1 set BAD=1
call :one 32
if errorlevel 1 set BAD=1
call :one 36
if errorlevel 1 set BAD=1
echo ===================================================================
if "%BAD%"=="1" (echo MUT5_GATE_ALL: FAIL & exit /b 1)
echo MUT5_GATE_ALL: OK (cfg=%CFG%: every width behaved as expected)
exit /b 0

REM ---------------------------------------------------------------------------
REM :one <W> -- run width W, compare verdict against the expected one.
REM ---------------------------------------------------------------------------
:one
set W=%1
set /a NBW=%W%*32
set EF=0
if /i "%CFG%"=="nolatch" set EF=1
if /i "%CFG%"=="nwbug" if "%W%"=="36" set EF=1
if "%EF%"=="1" (set EXPT=FAIL) else (set EXPT=PASS)
echo ---- cfg=%CFG% NW=%W% expect=%EXPT%
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d TB_NW_%W% "%DUT%" "%TB%" > xvlog_%CFG%_nw%W%.log 2>&1 || (type xvlog_%CFG%_nw%W%.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_%CFG%_nw%W%.log 2>&1 || (type xvlog_%CFG%_nw%W%.log & exit /b 1)
findstr /I /C:"implicitly" xvlog_%CFG%_nw%W%.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_%CFG%_nw%W%.log & exit /b 1)
findstr /C:"10-3091" xvlog_%CFG%_nw%W%.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & type xvlog_%CFG%_nw%W%.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_snap_cdc xil_defaultlib.glbl -s tb_snap_cdc -log xelab_%CFG%_nw%W%.log > NUL 2>&1 || (type xelab_%CFG%_nw%W%.log & exit /b 1)
call %XV%\xsim.bat tb_snap_cdc -runall -log xsim_%CFG%_nw%W%.log > NUL 2>&1
findstr /C:"PASS" /C:"FAIL" /C:"TIMEOUT" xsim_%CFG%_nw%W%.log
REM keep a committable copy of the RAW log (sim/**/*.log is gitignored; .txt is not)
if exist "%~dp0fingerprint_%CFG%.txt" copy /y "%~dp0fingerprint_%CFG%.txt" "%~dp0gate_%CFG%_nw%W%.txt" > NUL
type xsim_%CFG%_nw%W%.log >> "%~dp0gate_%CFG%_nw%W%.txt"
set FAILED=0
findstr /C:"TB_NW_SEL: NW=%W% NB=%NBW% MACRO=TB_NW_%W%" xsim_%CFG%_nw%W%.log >NUL || (echo   NW%W%-ECHO-MISMATCH-FAIL & set FAILED=1)
findstr /C:"TB_NW_SEL-WARN" xsim_%CFG%_nw%W%.log >NUL && (echo   NW%W%-TB-FELL-BACK-TO-DEFAULT & set FAILED=1)
findstr /C:"SKEW_SELFTEST: NW=%W% " xsim_%CFG%_nw%W%.log | findstr /C:"VERDICT=OK" >NUL || (echo   NW%W%-SKEW-SELFTEST-FAIL & set FAILED=1)
findstr /C:"PASS_ALL" xsim_%CFG%_nw%W%.log >NUL || (echo   NW%W%-PASS_ALL-MISSING & set FAILED=1)
if "%FAILED%"=="1" (
    if "%EF%"=="1" (echo   NW%W%-FAIL-AS-EXPECTED & exit /b 0)
    echo   NW%W%-UNEXPECTED-FAIL & exit /b 1
)
if "%EF%"=="1" (echo   NW%W%-NOT-CAUGHT & exit /b 1)
echo   NW%W%-PASS
exit /b 0
