@echo off
set "REPO_ROOT=%~dp0..\..\."
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

REM run_tb_p5_flow.bat -- P5b 窗口闭环门 (tb_p5_app.v -d P5_FLOW, 慢消费者 + 对端灌数据)
REM
REM 判据 (tools/gen_stim_p5_app.py flow, 规格 §3):
REM   ① 逐拍占用 occ <= winq + 2816 + 1518 (C1b 的 Δ) 且硬界 occ < 65528
REM   ② mac_rx_64.stat_drop == 0   ③ 通告右沿单调不降 (序比较)
REM   ④ 窗关(W=0) -> 恢复 -> 零重传完成 (图案逐字节)  ⑤ stat_fc_upd>0 + 活性
REM
REM 独立工作目录 sim\p5sim\flowrun (工程铁律: 残留 xsim 进程占 xsim.dir 会让门假失败)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set BD=%REPO_ROOT%\board
set TOOL=%REPO_ROOT%\tools
set SIM=%REPO_ROOT%\sim\p5b_ind3\flowrun

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"

%PY% %TOOL%\gen_stim_p5_app.py %SIM% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -d P5_FLOW ^
  %RTL%\crc32_8b.v ^
  %RTL%\fifo_sync.v ^
  %RTL%\checksum16.v ^
  %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v ^
  %RTL%\mac_tx_64.v ^
  %RTL%\tcp_cam.v ^
  %RTL%\tcb.v ^
  %RTL%\tcp_rx.v ^
  %RTL%\tcp_tx_frame.v ^
  %RTL%\retx_ram.v ^
  %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v ^
  %RTL%\rx_classify.v ^
  %RTL%\vlan_strip.v ^
  %RTL%\slow_cfg_adp.v ^
  %RTL%\tx_arb.v ^
  %RTL%\app_ctrl.v ^
  %RTL%\app_pattern.v ^
  %RTL%\app_status_uart.v ^
  %BD%\uart_dbg.v ^
  %TB%\tb_app_sink.v ^
  %TB%\tb_p5_app.v > xvlog_flow.log 2>&1 || (type xvlog_flow.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_flow.log 2>&1 || (type xvlog_flow.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5_app xil_defaultlib.glbl -s tb_p5_flow -log xelab_flow.log > NUL 2>&1 || (type xelab_flow.log & exit /b 1)
call %XV%\xsim.bat tb_p5_flow -runall -log xsim_flow.log > NUL 2>&1 || (type xsim_flow.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_app.py %SIM% flow
