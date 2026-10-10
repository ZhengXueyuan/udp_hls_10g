@echo off
REM ==========================================================================
REM probe_compile_wrapper.bat  (2026-10-10, task 4 feasibility probe)
REM   QUESTION: can board/wrapper_p4.v + rtl/app_pattern.v be added to the P4
REM   chain gate's compile list in the DEFAULT build (no macros) and still
REM   xvlog + xelab clean?
REM   METHOD: verbatim copy of sim\p4sim\run_tb_p4_chain.bat's xvlog/xelab
REM   steps, with 4 candidate files APPENDED to the second xvlog list.
REM   The TB is NOT changed: tb_p4_chain.v does not instantiate wrapper_p4,
REM   so this measures COMPILE-LEVEL coverage only (parse + width/undeclared
REM   diagnostics), never elaboration of the candidate modules.
REM   No repo file is modified. Work dir = work_probe\ under this dir.
REM   exit: 0 ok / 1 xvlog failed / 2 xelab failed / 9 pathguard
REM ==========================================================================
setlocal
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 9)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "HLS=%ROOT%\hls\slowstack_prj\solution1\syn\verilog"
set "W=%HERE%\work_probe"
if exist "%W%" rmdir /s /q "%W%"
mkdir "%W%"
cd /d "%W%"
if exist "%HLS%" (copy /y "%HLS%\*.dat" . >nul) else (echo [FAIL] HLS dir missing & exit /b 9)
(if exist "%HLS%\" (dir /b /s %HLS%\*.v)) > hls_files.f

echo [1/3] xvlog HLS netlist ...
call "%XV%\xvlog.bat" -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)

echo [2/3] xvlog rtl + tb + CANDIDATES ...
call "%XV%\xvlog.bat" -work xil_defaultlib ^
  "%ROOT%\rtl\crc32_8b.v" ^
  "%ROOT%\rtl\fifo_sync.v" ^
  "%ROOT%\rtl\checksum16.v" ^
  "%ROOT%\rtl\frame_fifo.v" ^
  "%ROOT%\rtl\mac_rx_64.v" ^
  "%ROOT%\rtl\mac_tx_64.v" ^
  "%ROOT%\rtl\tcp_cam.v" ^
  "%ROOT%\rtl\tcb.v" ^
  "%ROOT%\rtl\tcp_rx.v" ^
  "%ROOT%\rtl\tcp_tx_frame.v" ^
  "%ROOT%\rtl\retx_ram.v" ^
  "%ROOT%\rtl\tcp_echo.v" ^
  "%ROOT%\rtl\axis_pipe.v" ^
  "%ROOT%\rtl\rx_classify.v" ^
  "%ROOT%\rtl\vlan_strip.v" ^
  "%ROOT%\rtl\slow_cfg_adp.v" ^
  "%ROOT%\rtl\slow_rx_adp.v" ^
  "%ROOT%\rtl\slow_tx_adp.v" ^
  "%ROOT%\rtl\tx_arb.v" ^
  "%ROOT%\tb\tb_p4_chain.v" ^
  "%ROOT%\board\wrapper_p4.v" ^
  "%ROOT%\board\util_gmii_to_rgmii.v" ^
  "%ROOT%\board\uart_dbg.v" ^
  "%ROOT%\rtl\app_pattern.v" > xvlog_tb.log 2>&1 || (type xvlog_tb.log & echo XVLOG-CANDIDATE-FAIL & exit /b 1)
call "%XV%\xvlog.bat" -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

echo [3/3] xelab tb_p4_chain ...
call "%XV%\xelab.bat" -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & echo XELAB-CANDIDATE-FAIL & exit /b 2)
echo ---- implicit-decl gate (same 5 keys as the real gate) ----
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log
echo PROBE-COMPILE-OK
exit /b 0
