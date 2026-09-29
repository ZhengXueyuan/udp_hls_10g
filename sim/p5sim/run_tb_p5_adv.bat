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

REM run_tb_p5_adv.bat -- P5a adversarial cases (tb_p5_adv.v, built by the P5a
REM reviewer). Usage: run_tb_p5_adv.bat <case>   (case = len b2b wnd fin findrop
REM abort evfifo reconn_fast reconn_slow multi)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set TB=%REPO_ROOT%\tb
set BD=%REPO_ROOT%\board
set TOOL=%REPO_ROOT%\tools
set SIM=%REPO_ROOT%\sim\p5sim
set CASE=%1
if "%CASE%"=="" set CASE=len

%PY% %TOOL%\gen_stim_p5_adv.py %SIM% %CASE% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib_a ^
  %RTL%\crc32_8b.v %RTL%\fifo_sync.v %RTL%\checksum16.v %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v %RTL%\mac_tx_64.v %RTL%\tcp_cam.v %RTL%\tcb.v ^
  %RTL%\tcp_rx.v %RTL%\tcp_tx_frame.v %RTL%\retx_ram.v %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v %RTL%\rx_classify.v %RTL%\vlan_strip.v ^
  %RTL%\slow_cfg_adp.v %RTL%\udp_rx.v %RTL%\udp_split.v %RTL%\tx_arb.v %RTL%\app_ctrl.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v ^
  %TB%\tb_p5_adv.v > xvlog_adv.log 2>&1 || (type xvlog_adv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib_a "%XV%\..\data\verilog\src\glbl.v" >> xvlog_adv.log 2>&1 || (type xvlog_adv.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib_a.tb_p5_adv xil_defaultlib_a.glbl -s tb_p5_adv -log xelab_adv.log > NUL 2>&1 || (type xelab_adv.log & exit /b 1)
call %XV%\xsim.bat tb_p5_adv -runall -log xsim_adv_%CASE%.log > NUL 2>&1 || (type xsim_adv_%CASE%.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_adv.py %SIM% %CASE% check
