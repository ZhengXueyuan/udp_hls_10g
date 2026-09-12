@echo off
REM run_tb_uart_dbg.bat - uart_dbg unit TB: dbg_line_tx + uart_tx_9600
REM decodes 9600 framing (speed-up params), checks line1 / idle gap / line2
REM repeat / per-line TXST resample. Run from Git Bash:
REM   cmd //c D:\repo\ECO\udp_hls_10g\sim\tbgate\run_tb_uart_dbg.bat
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call %XV%\xvlog.bat -work xil_defaultlib ..\..\board\uart_dbg.v ..\..\tb\tb_uart_dbg.v > xvlog_uart.log 2>&1 || (type xvlog_uart.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_uart_dbg -s tb_uart_dbg -log xelab_uart.log > NUL 2>&1 || (type xelab_uart.log & exit /b 1)
call %XV%\xsim.bat tb_uart_dbg -runall -log xsim_uart.log > NUL 2>&1 || (type xsim_uart.log & exit /b 1)
