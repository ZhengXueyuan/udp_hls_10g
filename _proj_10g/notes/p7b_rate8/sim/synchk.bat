@echo off
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d "%~dp0"
set RTL=%~dp0..\..\..\..\rtl
del /q xvlog_*.log 2>NUL
echo === [1] default (no defines) ===
call %XV%\xvlog.bat -work xil_defaultlib "%RTL%\app_udp_pattern.v" > xvlog_a.log 2>&1
echo exit=%errorlevel%
findstr /I /C:"ERROR" /C:"WARNING" xvlog_a.log
echo === [2] -d P7B_10G ===
call %XV%\xvlog.bat -work xil_defaultlib -d P7B_10G "%RTL%\app_udp_pattern.v" > xvlog_b.log 2>&1
echo exit=%errorlevel%
findstr /I /C:"ERROR" /C:"WARNING" xvlog_b.log
echo === [3] -d P7B_10G -d RXP_DIAG ===
call %XV%\xvlog.bat -work xil_defaultlib -d P7B_10G -d RXP_DIAG "%RTL%\app_udp_pattern.v" > xvlog_c.log 2>&1
echo exit=%errorlevel%
findstr /I /C:"ERROR" /C:"WARNING" xvlog_c.log
echo SYNCHK-DONE
