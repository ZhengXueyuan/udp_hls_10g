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

REM run_tb_p5_udp_split.bat -- P5e pre-experiment A/B runner (ZERO RTL change)
REM
REM usage: run_tb_p5_udp_split.bat [base^|nostall^|stall^|harsh^|r2^|r2stall^|r3]
REM   base    : tb_p5_baseline.v = tb\tb_p5_app.v verbatim (module+resp name only)
REM   nostall : tb_p5_udp_split.v = baseline + (rx_classify slow port -> udp_rx),
REM             udp_rx m_axis_tready tied 1
REM   stall   : +UDPSTALL  -> tready 3 high 1 low  (light backpressure)
REM   harsh   : +UDPHARSH  -> 100 of every 2100 cycles ready (duty 0.048, far
REM             below the 0.125 1G word rate) => probes MAC 8-deep FIFO overflow
REM   r2      : P5E_ROUND=2 -> adds malformed-length / multicast frames
REM   r2stall : P5E_ROUND=2 + UDPSTALL
REM   r3      : P5E_ROUND=3 -> pcount 12-bit wrap probe (payload 4095/4096/5000)
REM
REM env P5SMALL=1 adds -d P5_SMALL (TB's own knob, TB_TX_BYTES=65536) to shorten
REM the run; default = full 1MB (comparable with the canonical P5a gate).
REM isolation: own xsim.dir here (project rule 7).  rtl\ is referenced READ-ONLY.
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=%REPO_ROOT%\rtl
set BD=%REPO_ROOT%\board
set SIM=%REPO_ROOT%\sim\p5e_pre
set CASE=%1
if "%CASE%"=="" set CASE=nostall
set PLUS=
set SRCF=tb_p5_udp_split.v
set MODL=tb_p5_udp_split
set DEF=
if /I "%CASE%"=="stall"   set PLUS=-testplusarg UDPSTALL
if /I "%CASE%"=="harsh"   set PLUS=-testplusarg UDPHARSH
if /I "%CASE%"=="r2stall" set PLUS=-testplusarg UDPSTALL
if /I "%CASE%"=="r2"      set P5E_ROUND=2
if /I "%CASE%"=="r2stall" set P5E_ROUND=2
if /I "%CASE%"=="r3"      set P5E_ROUND=3
if /I "%CASE%"=="base"   set SRCF=tb_p5_baseline.v
if /I "%CASE%"=="base"   set MODL=tb_p5_baseline
if "%P5SMALL%"=="1" set DEF=-d P5_SMALL

%PY% %SIM%\gen_stim_p5e_udp.py %SIM% || exit /b 1

if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib %DEF% ^
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
  %RTL%\udp_rx.v ^
  %RTL%\app_ctrl.v ^
  %RTL%\app_pattern.v ^
  %RTL%\app_status_uart.v ^
  %BD%\uart_dbg.v ^
  %SIM%\%SRCF% > xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.%MODL% xil_defaultlib.glbl -s %MODL%_%CASE% -log xelab_%CASE%.log > NUL 2>&1 || (type xelab_%CASE%.log & exit /b 1)
call %XV%\xsim.bat %MODL%_%CASE% -runall %PLUS% -log xsim_%CASE%.log > NUL 2>&1 || (type xsim_%CASE%.log & exit /b 1)

if /I "%CASE%"=="base" goto done
copy /y resp_p5_udp_split.memh resp_p5_udp_split_%CASE%.memh > NUL
%PY% %SIM%\gen_stim_p5e_udp.py %SIM% check
exit /b %ERRORLEVEL%

:done
echo BASE run complete: resp_p5_baseline.memh
exit /b 0
