@echo off
setlocal
set "REPO=%~dp0..\.."
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set SIM=%~dp0run
if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib %REPO%\rtl\fifo_sync.v %REPO%\rtl\app_ctrl.v %REPO%\tb\tb_app_wu.v > xvlog_wu.log 2>&1 || (type xvlog_wu.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_app_wu -s tb_app_wu -log xelab_wu.log > NUL 2>&1 || (type xelab_wu.log & exit /b 1)
call %XV%\xsim.bat tb_app_wu -runall -log xsim_wu.log > NUL 2>&1 || (type xsim_wu.log & exit /b 1)
type xsim_wu.log
findstr /C:"P7B WU GATE OK" xsim_wu.log > NUL
if errorlevel 1 (echo MYRUN WU GATE FAIL & exit /b 1)
echo MYRUN WU GATE PASS
