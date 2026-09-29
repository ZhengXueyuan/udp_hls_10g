@echo off
REM run_syn.bat -- syntax-only check of the xxv_loop RTL with xvlog.
REM   xvlog compiles file by file, so missing modules (pcs64, vio_0) are fine --
REM   it still catches every Verilog syntax error before the long Vivado build.
setlocal
cd /d %~dp0
call "C:\AMDDesignTools\2025.2\Vivado\bin\xvlog.bat" ..\rtl\obs_util.v ..\rtl\xgmii_rx_chk.v ..\rtl\xxv_loop_top.v ..\rtl\pcs64_pkt_gen_mon_ds.v -L xil_defaultlib
echo XVLOG_RC=%ERRORLEVEL%
exit /b %ERRORLEVEL%
