@echo off
set "REPO_ROOT=%~dp0..\..\..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)
rem --- pathguard tripwire: refuse to run if a LIVE line points outside ---
set "P4PY=C:\Users\zhxue\anaconda3\python.exe"
if exist "%P4PY%" goto :pg_py_ok
set "P4PY="
for %%P in (python.exe) do if not defined P4PY set "P4PY=%%~$PATH:P"
:pg_py_ok
if not defined P4PY goto :pg_sc_done
if not exist "%REPO_ROOT%\sim\p4gates\p4gate.py" goto :pg_sc_done
"%P4PY%" "%REPO_ROOT%\sim\p4gates\p4gate.py" selfcheck --root "%REPO_ROOT%" --bat "%~f0" --quiet || exit /b 1
:pg_sc_done

REM ============================================================
REM p5c_t3/rev -- static elaboration check for BOTH build configs.
REM   Compile the FULL wrapper (default build AND -d APP_MODE) and elaborate it
REM   as a top, so unconnected / undriven / multi-driven ports (the C12 class of
REM   defect) show up for the new P5c-T3 ports in every config. No TB.
REM Usage: cmd //c "D:\repo\ECO\udp_hls_10g\sim\p5c_t3\rev\run_wrapper_elab_chk.bat"
REM ============================================================
setlocal
set VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin
set GLBL=%VIV_BIN%\..\data\verilog\src\glbl.v
set RTL=%REPO_ROOT%\rtl
set BD=%REPO_ROOT%\board
set HLS=%REPO_ROOT%\hls\slowstack_prj\solution1\syn\verilog
set REV=%REPO_ROOT%\sim\p5c_t3\rev
cd /d %REV%
if exist wchk rmdir /s /q wchk
mkdir wchk
cd wchk
copy /y %HLS%\*.dat . >nul 2>&1
dir /b /s %HLS%\*.v > hls_files.f

set RTLF=%RTL%\crc32_8b.v %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\frame_fifo.v %RTL%\mac_rx_64.v %RTL%\mac_tx_64.v %RTL%\tcp_cam.v %RTL%\tcb.v %RTL%\tcp_rx.v %RTL%\tcp_tx_frame.v %RTL%\retx_ram.v %RTL%\tcp_echo.v %RTL%\axis_pipe.v %RTL%\rx_classify.v %RTL%\vlan_strip.v %RTL%\slow_rx_adp.v %RTL%\slow_cfg_adp.v %RTL%\slow_tx_adp.v %RTL%\udp_rx.v %RTL%\udp_split.v %RTL%\tx_arb.v %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v %RTL%\app_ctrl.v %RTL%\app_pattern.v %RTL%\app_udp_pattern.v %RTL%\app_status_uart.v %BD%\wrapper_p4.v %BD%\util_gmii_to_rgmii.v %BD%\uart_dbg.v %GLBL%

echo === [A] DEFAULT BUILD (no APP_MODE) ===
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib -f hls_files.f > xv_a.log 2>&1
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib %RTLF% >> xv_a.log 2>&1
call "%VIV_BIN%\xelab.bat" -L xil_defaultlib -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s wrap_a -log xe_a.log > NUL 2>&1
echo --- xvlog lines mentioning app_ctrl/rst_sent/ERROR ---
findstr /i /c:"app_ctrl" /c:"rst_sent" /c:"ERROR" xv_a.log
echo --- xelab warnings (unconnected/undriven/multi/driven) ---
findstr /i /c:"WARNING" /c:"unconnected" /c:"undriven" /c:"multi" /c:"driven" /c:"ERROR" xe_a.log

echo === [B] APP_MODE BUILD ===
if exist xsim.dir rmdir /s /q xsim.dir
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib -d APP_MODE -f hls_files.f > xv_b.log 2>&1
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib -d APP_MODE %RTLF% >> xv_b.log 2>&1
call "%VIV_BIN%\xelab.bat" -L xil_defaultlib -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s wrap_b -log xe_b.log > NUL 2>&1
echo --- xvlog lines mentioning app_ctrl/rst_sent/ERROR ---
findstr /i /c:"app_ctrl" /c:"rst_sent" /c:"ERROR" xv_b.log
echo --- xelab warnings (unconnected/undriven/multi/driven) ---
findstr /i /c:"WARNING" /c:"unconnected" /c:"undriven" /c:"multi" /c:"driven" /c:"ERROR" xe_b.log

REM --- verdict (2026-09-30): this gate used to end on "echo DONE" => exit 0
REM even when xelab had hard-failed (it swallowed a real "Module <udp_tx_cfg>
REM / <udp_tx_frame> not found" for both build configs).  Any ERROR line in
REM either elab log is now a hard failure.
findstr /C:"ERROR" xe_a.log xe_b.log >NUL
if not errorlevel 1 (
  echo [ELAB-CHK FAIL] xelab reported ERROR in one of the two configs:
  findstr /C:"ERROR" xe_a.log xe_b.log
  exit /b 1
)
echo [ELAB-CHK PASS] both configs elaborated with 0 ERROR lines
echo DONE (logs: wchk\xv_a.log xv_b.log xe_a.log xe_b.log)
exit /b 0
