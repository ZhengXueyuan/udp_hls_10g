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

REM run_tb_p4_replay.bat -- P4b-7-P6: p4b7_syn.pcapng PC->FPGA 流精确重放 (xsim)
REM   刺激由 tools/gen_stim_p4b7.py 预生成 (stim_data/dv/er.memh + cfg_tcb.memh),
REM   本 bat 只负责编译 (RTOLIM_FAST) + xsim 运行。
REM   arg1 = NOPCACK (default +PCACK); arg2 = run log name (default xsim_run.log)
REM   用法 (Git Bash): cmd //c 'D:\...\run_tb_p4_replay.bat NOPCACK xsim_runa.log'
cd /d %~dp0
if exist txdrop.memh del /q txdrop.memh
REM P4e: delete vlan.memh so this gate never inherits VLAN tagging from a
REM previous run_tb_p4_*_vlan.bat (gen_stim/apply both read that file).
if exist vlan.memh del /q vlan.memh
REM P1-2: the slow-peer gate leaves pcslow.memh behind -- delete it so this
REM gate runs with the default fast-peer model.
if exist pcslow.memh del /q pcslow.memh
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=%REPO_ROOT%\hls\slowstack_prj\solution1\syn\verilog
set XPA=-testplusarg PCACK
if "%1"=="NOPCACK" set XPA=
set RUNLOG=%2
if "%RUNLOG%"=="" set RUNLOG=xsim_run.log

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d RTOLIM_FAST ^
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
  %REPO_ROOT%\rtl\slow_rx_adp.v ^
  %REPO_ROOT%\rtl\slow_cfg_adp.v ^
  %REPO_ROOT%\rtl\slow_tx_adp.v ^
  %REPO_ROOT%\rtl\tx_arb.v ^
  %REPO_ROOT%\tb\tb_p4_chain.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall %XPA% -log %RUNLOG% > NUL 2>&1 || (type %RUNLOG% & exit /b 1)
REM verdict (2026-09-30): the xsim exit code alone cannot tell "ran to the end"
REM from "never started / died early" -- the TB must reach its final DONE line.
findstr /C:"DONE rx" %RUNLOG% >NUL || (echo [P4_REPLAY FAIL] TB never reached its final DONE line: & type %RUNLOG% & exit /b 1)
findstr /C:"DONE rx" %RUNLOG%
exit /b 0
