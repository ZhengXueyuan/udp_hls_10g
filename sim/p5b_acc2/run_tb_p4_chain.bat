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

REM run_tb_p4_chain.bat — P4a 全链 (含真 HLS udp_echo) xsim 一条线
REM 自生成刺激; 从 Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5b_acc2\run_tb_p4_chain.bat'
cd /d %~dp0
if exist txdrop.memh del /q txdrop.memh
REM P4b-7-P6: chain gate never truncates -- make sure no trunc.memh leaks in
REM from a previous run_tb_p4_burst.bat TRUNC run (TB/gen both read it).
if exist trunc.memh del /q trunc.memh
REM P4b-7-P6: same for the HALFDROP half-frame abort injection (halfdrop.memh).
if exist halfdrop.memh del /q halfdrop.memh
REM P4e: the VLAN gate leaves vlan.memh behind -- delete it so this default
REM gate runs without VLAN tagging (gen_stim/check both read that file).
if exist vlan.memh del /q vlan.memh
REM P1-2: the slow-peer gate leaves pcslow.memh behind -- delete it so this
REM gate runs with the default fast-peer model.
if exist pcslow.memh del /q pcslow.memh
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=%REPO_ROOT%\hls\slowstack_prj\solution1\syn\verilog

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

%PY% %REPO_ROOT%\tools\gen_stim_p4_chain.py %REPO_ROOT%\sim\p5b_acc2 || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib ^
  %REPO_ROOT%\rtl\crc32_8b.v ^
  %REPO_ROOT%\rtl\fifo_sync.v ^
  %REPO_ROOT%\rtl\checksum16.v ^
  %REPO_ROOT%\rtl\frame_fifo.v ^
  %REPO_ROOT%\rtl\mac_rx_64.v ^
  %REPO_ROOT%\rtl\mac_tx_64.v ^
  %REPO_ROOT%\rtl\tcp_cam.v ^
  %REPO_ROOT%\rtl\tcb.v ^
  %REPO_ROOT%\rtl\tcp_rx.v ^
  %REPO_ROOT%\rtl\tcp_tx_frame.v ^
  %REPO_ROOT%\rtl\retx_ram.v ^
  %REPO_ROOT%\rtl\tcp_echo.v ^
  %REPO_ROOT%\rtl\axis_pipe.v ^
  %REPO_ROOT%\rtl\rx_classify.v ^
  %REPO_ROOT%\rtl\vlan_strip.v ^
  %REPO_ROOT%\rtl\slow_cfg_adp.v ^
  %REPO_ROOT%\rtl\slow_rx_adp.v ^
  %REPO_ROOT%\rtl\slow_tx_adp.v ^
  %REPO_ROOT%\rtl\tx_arb.v ^
  %REPO_ROOT%\tb\tb_p4_chain.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

REM P4b-7-P6: frame_fifo 含 RAMB36E1/RAMB18E1 原语 -> xelab 需 -L unisims_ver + glbl
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

%PY% %REPO_ROOT%\tools\gen_stim_p4_chain.py %REPO_ROOT%\sim\p5b_acc2 check
