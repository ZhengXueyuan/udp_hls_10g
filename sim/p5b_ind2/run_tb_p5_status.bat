@echo off
REM run_tb_p5_status.bat -- app_status_uart unit gate (P5a Step 6)
REM decodes the 136-char status line from txd and compares it with the expected
REM string (gen_stim_p5_app.py checkstatus)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set BD=D:\repo\ECO\udp_hls_10g\board
set TOOL=D:\repo\ECO\udp_hls_10g\tools
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5b_ind2

if exist status_line.txt del /q status_line.txt

call %XV%\xvlog.bat -work xil_defaultlib_a ^
  %RTL%\app_status_uart.v ^
  %BD%\uart_dbg.v ^
  %TB%\tb_p5_status.v > xvlog_st.log 2>&1 || (type xvlog_st.log & exit /b 1)

call %XV%\xelab.bat xil_defaultlib_a.tb_p5_status -s tb_p5_status -log xelab_st.log > NUL 2>&1 || (type xelab_st.log & exit /b 1)
call %XV%\xsim.bat tb_p5_status -runall -log xsim_st.log > NUL 2>&1 || (type xsim_st.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_app.py %SIM% checkstatus
