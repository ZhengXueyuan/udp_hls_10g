@echo off
setlocal
REM =====================================================================
REM run_tb_app_udp_p7b.bat <mode> <wide|def>
REM   既有 p5e_udp 门的**宏变体** (tb/tb_app_udp.v 与 sim/p5e_udp 逐字同款 TB,
REM   只把 -d P7B_10G 加上/去掉, 并在本目录另开工作目录)。
REM   mode: pos | splitoff | portout | badcrc | nopeer | neglearn
REM   neglearn 期望 exit 1 (负对照); 其余期望 exit 0。
REM =====================================================================
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] cannot locate repo root from %~f0 & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "TB=%ROOT%\tb"
cd /d "%HERE%"

set "MODE=%~1"
set "VARIANT=%~2"
if "%MODE%"=="" set "MODE=pos"
if "%VARIANT%"=="" set "VARIANT=wide"
set "DEFS="
if /i "%VARIANT%"=="wide" set "DEFS=-d P7B_10G"

set "TPA="
if /i "%MODE%"=="splitoff" set TPA=-testplusarg SPLITOFF
if /i "%MODE%"=="portout"  set TPA=-testplusarg PORTOUT
if /i "%MODE%"=="badcrc"   set TPA=-testplusarg BADCRC
if /i "%MODE%"=="nopeer"   set TPA=-testplusarg NOPEER
if /i "%MODE%"=="neglearn" set TPA=-testplusarg NEGLEARN

if not exist "ua_%VARIANT%" mkdir "ua_%VARIANT%"
pushd "ua_%VARIANT%"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% ^
  "%RTL%\fifo_sync.v" "%RTL%\frame_fifo.v" "%RTL%\checksum16.v" ^
  "%RTL%\udp_rx.v" "%RTL%\udp_split.v" "%RTL%\slow_rx_adp.v" ^
  "%RTL%\udp_tx_cfg.v" "%RTL%\udp_tx_frame.v" "%RTL%\tx_arb.v" ^
  "%RTL%\app_udp_pattern.v" ^
  "%TB%\tb_app_udp.v" > w_xv.log 2>&1 || (type w_xv.log & popd & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" w_xv.log > NUL
if not errorlevel 1 (echo IMPLICIT-WIRE: & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" w_xv.log & popd & exit /b 1)
call "%XV%\xvlog.bat" -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> w_xv.log 2>&1 || (type w_xv.log & popd & exit /b 1)
call "%XV%\xelab.bat" -debug typical -L unisims_ver xil_defaultlib.tb_app_udp xil_defaultlib.glbl -s tb_app_udp -log w_xe.log > w_xe_out.log 2>&1 || (type w_xe_out.log & popd & exit /b 1)
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" w_xe.log > NUL
if not errorlevel 1 (echo ELAB-IMPLICIT: & findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"undeclared symbol" w_xe.log & popd & exit /b 1)
call "%XV%\xsim.bat" tb_app_udp -runall %TPA% -log w_xs_%MODE%.log > w_xs_out.log 2>&1
findstr /C:"P5E UDP APP GATE: OK" w_xs_%MODE%.log > NUL
if errorlevel 1 (echo ---- FAIL detail [%MODE%/%VARIANT%]: & findstr /C:"FAIL" w_xs_%MODE%.log & popd & exit /b 1)
findstr /C:"P5E UDP APP GATE" w_xs_%MODE%.log
popd
exit /b 0
