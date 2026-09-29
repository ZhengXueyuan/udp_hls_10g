@echo off
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RD=%~dp0rd_macrx
if not exist "%RD%" mkdir "%RD%"
cd /d "%RD%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib ..\..\rtl\mac_rx_64.v ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\rw\tb_rvw_macrx.v > xv_rv.log 2>&1 || (type xv_rv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv_rv.log 2>&1 || (type xv_rv.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_rv.log >NUL && (echo IMPLICIT-DECL-FAIL & type xv_rv.log & exit /b 1)
findstr /C:"10-3091" xv_rv.log >NUL && (echo BITWIDTH-FAIL & type xv_rv.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rvw_macrx xil_defaultlib.glbl -s tb_rvw -log xe_rv.log > NUL 2>&1 || (type xe_rv.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_rv.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_rv.log & exit /b 1)
call %XV%\xsim.bat tb_rvw -runall -log xs_rv.log > NUL 2>&1
type xs_rv.log
