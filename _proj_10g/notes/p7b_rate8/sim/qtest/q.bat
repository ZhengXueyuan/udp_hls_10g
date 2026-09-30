@echo off
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d "%~dp0"
set RTL=%~dp0..\..\..\..\..\rtl
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d P7B_10G "%RTL%\app_udp_pattern.v" "%RTL%\fifo_sync.v" "%~dp0..\tb_app8_equiv.v" > xv.log 2>&1 || (type xv.log & exit /b 1)
findstr /I /C:"ERROR" /C:"WARNING" xv.log
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_app8_equiv -s tb8 -log xe.log > NUL 2>&1 || (type xe.log & exit /b 1)
echo ELAB-OK
call %XV%\xsim.bat tb8 -runall -log xs.log > NUL 2>&1
type xs.log | findstr /C:"info" /C:"ok" /C:"FAIL" /C:"T0:" /C:"L0" /C:"L1" /C:"R0" /C:"R1" /C:"TB_APP8" /C:"TB8"
echo QT-DONE
