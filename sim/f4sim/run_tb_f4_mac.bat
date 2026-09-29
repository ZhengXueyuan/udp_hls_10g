@echo off
REM F4 gate runner.  usage: run_tb_f4_mac.bat [new|old|mut|nogate]
REM   new (default) = fixed rtl/mac_rx_64.v + rtl/fifo_sync.v (+define F4_NEWPORTS)
REM   old           = pre-fix copy (prefix_rtl/, git HEAD) -- mutation control, gate MUST FAIL
REM   mut           = F4-2 defect mutant (mut_newbug/: old S_TERM design + unconditional S_TERM entry)
REM   nogate        = TERM-priority gate removed (mut_nogate/: frame words may overtake the TERM)
setlocal
set MODE=%1
if "%MODE%"=="" set MODE=new
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=%~dp0..\..
set STIMDIR=%~dp0
if not "%STIM%"=="" set STIMDIR=%~dp0%STIM%\
set RD=%~dp0rd_%MODE%
if not exist "%RD%" mkdir "%RD%"
cd /d "%RD%"
for %%F in (f4_data.memh f4_dv.memh f4_er.memh f4_wr.memh f4_cases.txt) do (
  copy /Y "%STIMDIR%%%F" "%%F" >NUL
)
if exist xsim.dir rmdir /s /q xsim.dir
if "%MODE%"=="old" (
  set DUT=%ROOT%\sim\f4sim\prefix_rtl\mac_rx_64.v %ROOT%\sim\f4sim\prefix_rtl\fifo_sync.v
  set DEFS=
) else if "%MODE%"=="mut" (
  set DUT=%ROOT%\sim\f4sim\mut_newbug\mac_rx_64.v %ROOT%\sim\f4sim\mut_newbug\fifo_sync.v
  set DEFS=-d F4_NEWPORTS
) else if "%MODE%"=="mutcrs" (
  set DUT=%ROOT%\sim\f4sim\mut_termcrs\mac_rx_64.v %ROOT%\rtl\fifo_sync.v
  set DEFS=-d F4_NEWPORTS
) else if "%MODE%"=="nogate" (
  set DUT=%ROOT%\sim\f4sim\mut_nogate\mac_rx_64.v %ROOT%\rtl\fifo_sync.v
  set DEFS=-d F4_NEWPORTS
) else (
  set DUT=%ROOT%\rtl\mac_rx_64.v %ROOT%\rtl\fifo_sync.v
  set DEFS=-d F4_NEWPORTS
)
call %XV%\xvlog.bat %DEFS% -work xil_defaultlib %DUT% %ROOT%\rtl\crc32_8b.v %ROOT%\tb\tb_mac_rx_f4.v > xv_f4.log 2>&1 || (type xv_f4.log & echo XVLOG-FAIL & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv_f4.log 2>&1 || (type xv_f4.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_f4.log >NUL && (echo IMPLICIT-DECL-FAIL & type xv_f4.log & exit /b 1)
findstr /C:"10-3091" xv_f4.log >NUL && (echo BITWIDTH-FAIL & type xv_f4.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_mac_rx_f4 xil_defaultlib.glbl -s tb_f4 -log xe_f4.log > NUL 2>&1 || (type xe_f4.log & echo XELAB-FAIL & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_f4.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_f4.log & exit /b 1)
call %XV%\xsim.bat tb_f4 -runall -log xs_f4.log > NUL 2>&1
call %XV%\xsim.bat tb_f4 -runall -testplusarg NODRAIN -log xs_f4_nodrain.log > NUL 2>&1
findstr /C:"NODRAIN" xs_f4_nodrain.log
type xs_f4.log
findstr /C:"F4_GATE: PASS_ALL" xs_f4.log >NUL
if errorlevel 1 (echo F4-GATE-RESULT: FAIL & exit /b 1)
echo F4-GATE-RESULT: PASS_ALL
exit /b 0
