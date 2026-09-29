@echo off
REM run_tb_uart_dbg.bat - uart_dbg unit TB: dbg_line_tx + uart_tx_9600
REM decodes 9600 framing (speed-up params), checks line1 / idle gap / line2
REM repeat / per-line TXST resample. Run from Git Bash:
REM   cmd //c %REPO_ROOT%\sim\tbgate\run_tb_uart_dbg.bat
cd /d %~dp0
call "%~dp0..\p4gates\p4env.bat" || exit /b 1
if not "%P4_WORKDIR%"=="" cd /d "%P4_WORKDIR%"
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --path "%CD%" --quiet || exit /b 1
"%PY%" "%P4GATE_PY%" checkpaths --root "%REPO_ROOT%" --manifest "%GATES%\uart_src.f" --path "%CD%" --quiet || exit /b 1
call %XV%\xvlog.bat -work xil_defaultlib %BOARD%\uart_dbg.v %TB%\tb_uart_dbg.v > xvlog_uart.log 2>&1 || (type xvlog_uart.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_uart_dbg -s tb_uart_dbg -log xelab_uart.log > NUL 2>&1 || (type xelab_uart.log & exit /b 1)
call %XV%\xsim.bat tb_uart_dbg -runall -log xsim_uart.log > NUL 2>&1 || (type xsim_uart.log & exit /b 1)
