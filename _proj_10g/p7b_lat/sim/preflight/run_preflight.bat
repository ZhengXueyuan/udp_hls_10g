@echo off
REM run_preflight.bat -- cheap syntax/implicit-net preflight for the P7B_LAT build.
REM   xvlog is a PARSER: submodule bodies are not needed, so this catches syntax
REM   errors, undeclared symbols and (via its own messages) anything suspicious
REM   in wrapper_p4.v + the two new p7b_lat files BEFORE a 40 minute build.
setlocal
cd /d %~dp0
set XB=C:\AMDDesignTools\2025.2\Vivado\bin
REM   -*- xvlog takes `-d NAME` WITHOUT a value (a trailing "=1" is parsed as a FILE
REM       name and yields "ERROR: [XSIM 43-4316] Can not find file: 1").  -*-
call "%XB%\xvlog.bat" -d APP_MODE -d DEV_USP -d PCIE_OBS -d DP_156MHZ -d P7B_10G -d P7B_LAT --nolog -work work "%~dp0vio_lat_stub.v" "%~dp0..\..\rtl\p7b_lat_top.v" "%~dp0..\..\rtl\p7b_lat_drp.v" "%~dp0..\..\..\..\board\wrapper_p4.v" > "%~dp0xvlog_lat.log" 2>&1
echo XVLOG_EXIT=%ERRORLEVEL%
echo ---- HITS ----
findstr /I /C:"ERROR" /C:"VRFC 10-2989" /C:"undeclared" /C:"implicitly declared" /C:"8-11241" "%~dp0xvlog_lat.log"
echo ---- TAIL ----
type "%~dp0xvlog_lat.log"
exit /b 0
