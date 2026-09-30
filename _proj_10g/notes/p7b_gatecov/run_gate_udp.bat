@echo off
REM ===========================================================================
REM run_gate_udp.bat -- arm runner for sim/p5e_udp/run_tb_app_udp.bat
REM
REM Same rationale as run_gate_rate.bat: the shipped gate hardcodes
REM %REPO_ROOT%\rtl\app_udp_pattern.v, so a frozen mutant cannot be compiled by
REM it.  This repeats the shipped recipe (same file list, same TB source
REM tb\tb_app_udp.v, same testplusarg) and adds the app source + extra defines.
REM The JUDGE below is the shipped gate's judge, verbatim.
REM
REM usage: run_gate_udp.bat <mode> <abs-path-to-app_udp_pattern.v> [tgtdir] [extra -d ...]
REM   mode : pos / splitoff / portout / badcrc / nopeer / neglearn
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

set "MODE=%~1"
set "APP=%~2"
set "TGT=%~3"
set "EXTRA=%~4"
if "%MODE%"=="" echo usage: run_gate_udp.bat ^<mode^> ^<app_udp_pattern.v^> [tgtdir] [extra] & exit /b 1
if not exist "%APP%" echo [ARM FAIL] mutant RTL not found: %APP% & exit /b 1

set TPA=
if /i "%MODE%"=="splitoff" set TPA=-testplusarg SPLITOFF
if /i "%MODE%"=="portout"  set TPA=-testplusarg PORTOUT
if /i "%MODE%"=="badcrc"   set TPA=-testplusarg BADCRC
if /i "%MODE%"=="nopeer"   set TPA=-testplusarg NOPEER
if /i "%MODE%"=="neglearn" set TPA=-testplusarg NEGLEARN

REM --- extra defines: LITERAL string, e.g. "-d P7B_10G" ---
set "DEXTRA=%UDP_ARM_DEFS%"
if not "%~4"=="" set "DEXTRA=%DEXTRA% -d %~4"

if "%TGT%"=="" set "TGT=%HERE%logs\udp_%MODE%_arm"
if "%TGT:~0,1%"=="\" goto :tgt_abs
set "TGT=%HERE%%TGT%"
:tgt_abs
if not exist "%TGT%" mkdir "%TGT%"
cd /d "%TGT%"

set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb

echo === ARM: mode=%MODE% extra=[%EXTRA%] ===
echo === APP: %APP%
echo === TGT: %TGT%
certutil -hashfile "%APP%" MD5 | findstr /R /V "hash CertUtil"

if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %DEXTRA% ^
  %RTL%\fifo_sync.v %RTL%\frame_fifo.v %RTL%\checksum16.v ^
  %RTL%\udp_rx.v %RTL%\udp_split.v %RTL%\slow_rx_adp.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v %RTL%\tx_arb.v ^
  "%APP%" ^
  %TB%\tb_app_udp.v > xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver %DEXTRA% xil_defaultlib.tb_app_udp xil_defaultlib.glbl -s tb_app_udp -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log > NUL
if not errorlevel 1 (echo ERROR: implicit wire declaration in xelab: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_app_udp -runall %TPA% -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

REM ---- shipped gate's judge (verbatim) ----
findstr /C:"P5E UDP APP GATE: OK" xsim_run.log > NUL
if errorlevel 1 (echo ---- FAIL detail [%MODE%]: & findstr /C:"FAIL" xsim_run.log & exit /b 1)
findstr /C:"P5E UDP APP GATE" xsim_run.log
exit /b 0
