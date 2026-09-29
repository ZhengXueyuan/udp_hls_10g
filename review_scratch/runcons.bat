@echo off
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RD=%~dp0rd_cons
if not exist "%RD%" mkdir "%RD%"
cd /d "%RD%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib ..\..\rtl\mac_rx_64.v ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\rw\tb_rvw_conserve.v > xv.log 2>&1 || (type xv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv.log 2>&1 || (type xv.log & exit /b 1)
findstr /I /C:"implicitly" xv.log >NUL && (echo IMPLICIT-DECL-FAIL & type xv.log & exit /b 1)
findstr /C:"10-3091" xv.log >NUL && (echo BITWIDTH-FAIL & type xv.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_rvw_conserve xil_defaultlib.glbl -s tb_cs -log xe.log > NUL 2>&1 || (type xe.log & exit /b 1)
call %XV%\xsim.bat tb_cs -runall -log xs.log > NUL 2>&1
type xs.log
