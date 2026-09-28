@echo off
REM run_preflight.bat - KU5P (DEV_USP + APP_MODE) xvlog preflight: syntax / implicit nets only
REM   runs in its own dir so it does not fight other xsim runs over xsim.dir
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set HLS=%ROOT%\hls\slowstack_prj\solution1\syn\verilog
if exist hls_files.f del /q hls_files.f
(dir /b /s %HLS%\*.v) > hls_files.f
if exist pf.log del /q pf.log
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP -f hls_files.f > pf.log 2>&1 || (type pf.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP -f rtl_files.f >> pf.log 2>&1
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP %ROOT%\board\wrapper_p4.v %ROOT%\board\util_gmii_to_rgmii_us.v %ROOT%\board\util_gmii_to_rgmii.v %ROOT%\board\uart_dbg.v >> pf.log 2>&1
echo ---- implicit nets ----
findstr /I /C:"implicitly" pf.log
echo ---- errors ----
findstr /I /C:"ERROR" pf.log
echo ==== PREFLIGHT DONE (no ERROR line = pass) ====
