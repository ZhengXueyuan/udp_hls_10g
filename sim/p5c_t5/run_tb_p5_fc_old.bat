@echo off
REM run_tb_p5_fc_old.bat -- NEGATIVE CONTROL: old criterion (no activity term)
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5c_t5\oldrun

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib %RTL%\fifo_sync.v app_ctrl_old.v %TB%\tb_app_fc.v > xvlog_old.log 2>&1 || (type xvlog_old.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_app_fc -s tb_app_fc -log xelab_old.log > xelab_old_out.log 2>&1 || (type xelab_old.log & exit /b 1)
call %XV%\xsim.bat tb_app_fc -runall -log xsim_old.log > xsim_old_out.log 2>&1 || (type xsim_old.log & exit /b 1)
echo --- OLD RTL RESULT (expect FAIL) ---
findstr /C:"FC UNIT" xsim_old.log
findstr /C:"FC UNIT FAIL" xsim_old.log > nul && (echo OLD_RTL_FAILS_AS_EXPECTED & exit /b 0)
echo OLD_RTL_UNEXPECTEDLY_OK
