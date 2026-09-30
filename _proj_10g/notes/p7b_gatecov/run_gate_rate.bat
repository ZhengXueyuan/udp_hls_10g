@echo off
REM ===========================================================================
REM run_gate_rate.bat -- counterexample/arm runner for sim/p5e_rate/run_tb_rate.bat
REM
REM WHY THIS FILE EXISTS (P7B gate-coverage closeout, 2026-09-30):
REM   To prove a gate "has teeth" you must run the SAME harness twice: once with
REM   the defective RTL, once with the fixed RTL.  The shipped gate hardcodes
REM   %REPO_ROOT%\rtl\app_udp_pattern.v, so it cannot compile a frozen mutant.
REM   This runner repeats the shipped gate's recipe LINE FOR LINE (same file
REM   list, same TB source tb\tb_app_udp_rate.v, same cfg defines) and adds
REM   exactly two knobs: the app_udp_pattern.v source path and extra defines.
REM   The JUDGE below is the shipped gate's judge, verbatim.
REM
REM usage: run_gate_rate.bat <cfg> <abs-path-to-app_udp_pattern.v> [tgtdir] [extra -d ...]
REM   cfg        : g0p1472 / g58000p1472 / p996 / ...  (same names as the gate)
REM   tgtdir     : run dir (default = logs\rate_<cfg>_<appstem>)
REM   extra      : extra defines, e.g. "P7B_10G" (space separated, bare names)
REM
REM NOTE: keep this file ASCII-only + CRLF (project bat pitfall).
REM ===========================================================================
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..\..\..") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

set "CFG=%~1"
set "APP=%~2"
set "TGT=%~3"
set "EXTRA=%~4"
if "%CFG%"=="" echo usage: run_gate_rate.bat ^<cfg^> ^<app_udp_pattern.v^> [tgtdir] [extra-defines] & exit /b 1
if not exist "%APP%" echo [ARM FAIL] mutant RTL not found: %APP% & exit /b 1

REM --- derive cfg defines exactly like the shipped gate ---
set DM=
set DPL=
echo %CFG% | findstr /I /C:"g58000" > NUL && set DM=-d GAP58000
echo %CFG% | findstr /I /C:"g5000"  > NUL && set DM=-d GAP5000
echo %CFG% | findstr /I /C:"g2760"  > NUL && set DM=-d GAP2760
echo %CFG% | findstr /I /C:"g1380"  > NUL && set DM=-d GAP1380
echo %CFG% | findstr /I /C:"p996"   > NUL && set DPL=-d PL996
echo %CFG% | findstr /I /C:"p512"   > NUL && set DPL=-d PL512

REM --- extra defines: LITERAL string, e.g. "-d P7B_10G" (do NOT bare-name them:
REM     "call set" + for-loop mangles %%DEXTRA%% into %%D + EXTRA + %%) ---
set "DEXTRA=%RATE_ARM_DEFS%"
if not "%~4"=="" set "DEXTRA=%DEXTRA% -d %~4"

if "%TGT%"=="" set "TGT=%HERE%logs\rate_%CFG%_arm"
if "%TGT:~0,1%"=="\" goto :tgt_abs
set "TGT=%HERE%%TGT%"
:tgt_abs
if not exist "%TGT%" mkdir "%TGT%"
cd /d "%TGT%"

set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb

echo === ARM: cfg=%CFG% extra=[%EXTRA%] ===
echo === APP: %APP%
echo === TGT: %TGT%
for %%F in ("%APP%") do echo === APP md5/who: %%~nxF
certutil -hashfile "%APP%" MD5 | findstr /R /V "hash CertUtil"

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DM% %DPL% %DEXTRA% ^
  %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\crc32_8b.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v %RTL%\mac_tx_64.v ^
  "%APP%" ^
  %TB%\tb_app_udp_rate.v > xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver %DM% %DPL% %DEXTRA% xil_defaultlib.tb_app_udp_rate -s tb_rate_%CFG% -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xelab: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log & exit /b 1)

call %XV%\xsim.bat tb_rate_%CFG% -runall -log xsim_run.log > NUL 2>&1
findstr /C:"RATE TB DONE" xsim_run.log > NUL
if errorlevel 1 (echo RATE TB DID NOT FINISH & type xsim_run.log & exit /b 1)
findstr /C:"[pre" xsim_run.log & findstr /C:"--- tb_app_udp_rate" xsim_run.log
findstr /C:"frames on wire" xsim_run.log
findstr /C:"mean frame period" xsim_run.log
findstr /C:"mean wire len" xsim_run.log
findstr /C:"PAYLOAD RATE" xsim_run.log
findstr /C:"WIRE RATE" xsim_run.log
findstr /C:"app tx_frames" xsim_run.log
findstr /C:"P7B-W9" xsim_run.log
findstr /C:"C1 contract" xsim_run.log
findstr /C:"C2 framer" xsim_run.log
findstr /C:"C3 wire" xsim_run.log
findstr /C:"coverage:" xsim_run.log
findstr /C:"FAIL" xsim_run.log
findstr /C:"RATE GATE" xsim_run.log
REM ---- shipped gate's judge (verbatim: it is a print-only gate) ----
echo harness=run_gate_rate.cfg=%CFG% (same TB + same judge as the shipped gate)
exit /b 0
