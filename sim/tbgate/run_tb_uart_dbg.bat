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
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_uart.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_uart.log & exit /b 1)
call %XV%\xsim.bat tb_uart_dbg -runall -log xsim_uart.log > NUL 2>&1 || (type xsim_uart.log & exit /b 1)
REM ---- P7B: verdict visibility + teeth.  This TB reports its criterion as a PRINTED
REM   line (ALL_OK / 'FAIL: N mismatches') and never calls $fatal, so xsim returns 0
REM   either way: the gate used to exit 0 with the verdict living ONLY inside
REM   xsim_uart.log (measured: _gate_console.log held 1 line).  It is the 3rd
REM   console-silent gate of the 16; unit_retx / unit_fifo carry their verdict into
REM   the matrix log with the same 'type' step, so this one does too -- plus a hard
REM   failure so the verdict line cannot be ignored.
type xsim_uart.log
REM   FAIL first: a failing TB prints FAIL lines and NO ALL_OK, so testing ALL_OK
REM   first would report VERDICT-MISSING on a real failure (measured 2026-09-29).
findstr /C:"FAIL:" xsim_uart.log >NUL && (echo UART-TB-FAIL & findstr /C:"FAIL:" xsim_uart.log & exit /b 1)
findstr /C:"ALL_OK" xsim_uart.log >NUL || (echo UART-TB-VERDICT-MISSING & exit /b 1)
echo UART-GATE-OK
exit /b 0
