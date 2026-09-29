@echo off
REM run_sim_pay.bat -- xsim check of the pay_sel path in the traffic copy.
REM   Self-contained: pcs64_pkt_gen_mon_ds has all of its submodules in one file,
REM   so no IP is required.  SIM_SPEED_UP shortens the vendor FSM's arming window.
setlocal
cd /d %~dp0
set VIV=C:\AMDDesignTools\2025.2\Vivado\bin
if exist xsim.dir rmdir /s /q xsim.dir
call "%VIV%\xvlog.bat" --work xil_defaultlib -d SIM_SPEED_UP ..\rtl\pcs64_pkt_gen_mon_ds.v tb_pay_sel.v -L xil_defaultlib > xvlog_pay.log 2>&1
echo XVLOG_RC=%ERRORLEVEL%
call "%VIV%\xelab.bat" -d SIM_SPEED_UP xil_defaultlib.tb_pay_sel -s tbpay --debug typical -L xil_defaultlib > xelab_pay.log 2>&1
echo XELAB_RC=%ERRORLEVEL%
call "%VIV%\xsim.bat" tbpay -R > xsim_pay.log 2>&1
echo XSIM_RC=%ERRORLEVEL%
findstr /C:"TBCASE" /C:"TB START" /C:"TB DONE" /C:"ERROR" /C:"Error" xsim_pay.log
exit /b %ERRORLEVEL%
