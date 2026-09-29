@echo off
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set W=%~dp0probe_cfg_work
if exist "%W%" rmdir /s /q "%W%"
mkdir "%W%"
cd /d "%W%"
echo ##### CONFIG B: DEV_USP+APP_MODE, util_gmii_to_rgmii_us #####
dir /b /s "%ROOT%\rtl\*.v" > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v >> files.f
echo %ROOT%\board\uart_dbg.v >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvB.log 2>&1
echo XVLOG_B=%ERRORLEVEL%
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP "%XV%\..\data\verilog\src\glbl.v" >> xvB.log 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s cfgB -log xeB.log > NUL 2>&1
echo XELAB_B=%ERRORLEVEL%
findstr /C:"Built simulation snapshot" xeB.log >NUL && echo SNAPSHOT_B=yes || echo SNAPSHOT_B=NO
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xeB.log && echo NARROW-HIT-B || echo NARROW-CLEAN-B
echo --- config B errors ---
findstr /C:"ERROR" xeB.log
echo ##### CONFIG C: default (K7 shim util_gmii_to_rgmii.v) #####
del /q files.f >NUL
dir /b /s "%ROOT%\rtl\*.v" > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v >> files.f
echo %ROOT%\board\util_gmii_to_rgmii.v >> files.f
echo %ROOT%\board\uart_dbg.v >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvC.log 2>&1
echo XVLOG_C=%ERRORLEVEL%
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvC.log 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s cfgC -log xeC.log > NUL 2>&1
echo XELAB_C=%ERRORLEVEL%
findstr /C:"Built simulation snapshot" xeC.log >NUL && echo SNAPSHOT_C=yes || echo SNAPSHOT_C=NO
echo --- C: BROAD 10-3091 (expected: benign util_gmii literals) ---
findstr /C:"10-3091" xeC.log | findstr /C:"util_gmii_to_rgmii.v" | findstr /C:"formal bit length 1 "
echo --- C: NARROW key (must be clean) ---
findstr /I /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" xeC.log && echo NARROW-HIT-C || echo NARROW-CLEAN-C
echo --- C: all 5 keys ---
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xeC.log && echo KEYS-HIT-C || echo KEYS-CLEAN-C
echo --- config C errors ---
findstr /C:"ERROR" xeC.log
echo PROBE-CFG-DONE
