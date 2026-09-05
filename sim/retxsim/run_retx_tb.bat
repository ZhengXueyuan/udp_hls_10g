@echo off
REM run_retx_tb.bat -- P4b-7-P1: retx_ram unit testbench
REM   usage (Git Bash): cmd //c 'D:\repo\ECO\udp_hls_10g\sim\retxsim\run_retx_tb.bat'
REM   compiles rtl/retx_ram.v + tb/tb_retx_ram.v, runs xsim, prints xsim.log
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb

call %XV%\xvlog.bat -work xil_defaultlib ^
  %RTL%\retx_ram.v ^
  %TB%\tb_retx_ram.v > xvlog_c.log 2>&1 || (type xvlog_c.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_retx_ram -s tb_retx_ram -log xelab.log > NUL 2>&1 || (type xelab.log & exit /b 1)

call %XV%\xsim.bat tb_retx_ram -runall -log xsim.log > NUL 2>&1

type xsim.log
