@echo off
setlocal
set "HERE=%~dp0"
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
cd /d "%HERE%"
call "%XV%\xvlog.bat" -work xil_defaultlib ..\..\rtl\tcp_tx_frame.v > lint_off\xv.log 2>&1
echo OFF-RC=%errorlevel%
findstr /I /C:"ERROR" /C:"implicitly declared" /C:"VRFC 10-2989" /C:"VRFC 10-3091" lint_off\xv.log
call "%XV%\xvlog.bat" -work xil_defaultlib -d TCP_TX_OVL ..\..\rtl\tcp_tx_frame.v > lint_on\xv.log 2>&1
echo ON-RC=%errorlevel%
findstr /I /C:"ERROR" /C:"implicitly declared" /C:"VRFC 10-2989" /C:"VRFC 10-3091" lint_on\xv.log
echo DONE
