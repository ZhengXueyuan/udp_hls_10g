@echo off
REM =====================================================================
REM run_eq.bat -- default vs UDP_TX_OVL byte-for-byte equivalence gate
REM Owner: RTL implementation agent (P7B rate, framer overlap).
REM Writes ONLY under _proj_10g\notes\p7b_ratefrm\. rtl/ is READ-ONLY here.
REM Usage: run_eq.bat            (both configs + diff)
REM        run_eq.bat def        (default build only)
REM        run_eq.bat ovl        (UDP_TX_OVL build only)
REM =====================================================================
setlocal
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "MODE=%1"

if "%MODE%"=="" goto :both
if /i "%MODE%"=="def" goto :def
if /i "%MODE%"=="ovl" goto :ovl
echo usage: run_eq.bat [def^|ovl] & exit /b 97

:both
call "%~f0" def || exit /b 1
call "%~f0" ovl || exit /b 1
echo ==== BYTE-COMPARE (frames) ====
fc /b "%HERE%\run_def\eq_frames.txt" "%HERE%\run_ovl\eq_frames.txt" > "%HERE%\logs\frames_fc.txt"
if errorlevel 1 (echo FRAMES-DIFFER & exit /b 1)
echo FRAMES-IDENTICAL
echo ==== o_busy trace (informational; sizes may differ) ====
for %%F in ("%HERE%\run_def\eq_busy.txt") do echo def busy chars = %%~zF
for %%F in ("%HERE%\run_ovl\eq_busy.txt") do echo ovl busy chars = %%~zF
exit /b 0

:def
if exist "%HERE%\run_def\xsim.dir" rmdir /s /q "%HERE%\run_def\xsim.dir"
cd /d "%HERE%\run_def"
del /q xsim.log eq_frames.txt eq_busy.txt eq_events.txt 2>NUL
call "%XV%\xvlog.bat" -work xil_defaultlib -d DUMP_TRACE ^
  "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\udp_tx_frame.v" "%RTL%\udp_tx_cfg.v" ^
  "%HERE%\tb_ovl_eq.v" > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_tb.log > NUL
if not errorlevel 1 (echo IMPLICIT-DECL-FAIL: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_tb.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_ovl_eq -s tb_ovl_eq -log xelab_tb.log > NUL 2>&1 || (type xelab_tb.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_tb.log > NUL
if not errorlevel 1 (echo IMPLICIT-DECL-FAIL-XELAB: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_tb.log & exit /b 1)
call "%XV%\xsim.bat" tb_ovl_eq -runall -log xsim.log > NUL 2>&1 || (type xsim.log & exit /b 1)
echo ---- EQ [DEFAULT build, no macro] ----
findstr /C:"TB_OVL_EQ" /C:"WIRE frames" /C:"BUSY" /C:"DENY" /C:"PEER-SWITCH" /C:"TOTAL CYCLES" /C:"OVL EQ GATE" xsim.log
findstr /C:"OVL EQ GATE: OK" xsim.log > NUL || (echo EQ-DEF-FAIL & exit /b 1)
exit /b 0

:ovl
if exist "%HERE%\run_ovl\xsim.dir" rmdir /s /q "%HERE%\run_ovl\xsim.dir"
cd /d "%HERE%\run_ovl"
del /q xsim.log eq_frames.txt eq_busy.txt eq_events.txt 2>NUL
call "%XV%\xvlog.bat" -work xil_defaultlib -d DUMP_TRACE -d UDP_TX_OVL ^
  "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" "%RTL%\udp_tx_frame.v" "%RTL%\udp_tx_cfg.v" ^
  "%HERE%\tb_ovl_eq.v" > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_tb.log > NUL
if not errorlevel 1 (echo IMPLICIT-DECL-FAIL: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_tb.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_ovl_eq -s tb_ovl_eq -log xelab_tb.log > NUL 2>&1 || (type xelab_tb.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_tb.log > NUL
if not errorlevel 1 (echo IMPLICIT-DECL-FAIL-XELAB: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_tb.log & exit /b 1)
call "%XV%\xsim.bat" tb_ovl_eq -runall -log xsim.log > NUL 2>&1 || (type xsim.log & exit /b 1)
echo ---- EQ [UDP_TX_OVL build] ----
findstr /C:"TB_OVL_EQ" /C:"WIRE frames" /C:"BUSY" /C:"DENY" /C:"PEER-SWITCH" /C:"TOTAL CYCLES" /C:"OVL EQ GATE" xsim.log
findstr /C:"OVL EQ GATE: OK" xsim.log > NUL || (echo EQ-OVL-FAIL & exit /b 1)
exit /b 0
