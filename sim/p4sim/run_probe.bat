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

cd /d %~dp0
if exist txdrop.memh del /q txdrop.memh
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > /dev/null 2>&1
call %XV%\xvlog.bat -work xil_defaultlib %REPO_ROOT%\rtl\crc32_8b.v %REPO_ROOT%\rtl\fifo_sync.v %REPO_ROOT%\rtl\checksum16.v %REPO_ROOT%\rtl\frame_fifo.v %REPO_ROOT%\rtl\mac_rx_64.v %REPO_ROOT%\rtl\mac_tx_64.v %REPO_ROOT%\rtl\tcp_cam.v %REPO_ROOT%\rtl\tcb.v %REPO_ROOT%\rtl\tcp_rx.v %REPO_ROOT%\rtl\tcp_tx_frame.v %REPO_ROOT%\rtl\retx_ram.v %REPO_ROOT%\rtl\tcp_echo.v %REPO_ROOT%\rtl\axis_pipe.v %REPO_ROOT%\rtl\tcp_synp.v %REPO_ROOT%\rtl\rx_classify.v %REPO_ROOT%\rtl\slow_rx_adp.v %REPO_ROOT%\rtl\slow_tx_adp.v %REPO_ROOT%\rtl\tx_arb.v %REPO_ROOT%\tb\tb_p4_chain.v > /dev/null 2>&1 || (echo XVLOG_FAIL & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_probe -log xelab_probe.log > /dev/null 2>&1 || (echo XELAB_FAIL & exit /b 1)

call %XV%\xsim.bat tb_probe -runall -log xsim_probe.log > /dev/null 2>&1 || (echo XSIM_FAIL & exit /b 1)
echo PROBE_DONE
