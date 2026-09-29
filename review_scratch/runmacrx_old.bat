@echo off
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RD=%~dp0rd_macrx_old
if not exist "%RD%" mkdir "%RD%"
cd /d "%RD%"
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib ..\rw\mac_rx_64_asold.v ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\..\tb\tb_mac_rx_64.v > xv.log 2>&1 || (type xv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv.log 2>&1 || (type xv.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_mac_rx_64 xil_defaultlib.glbl -s tb_mrx -log xe.log > NUL 2>&1 || (type xe.log & exit /b 1)
call %XV%\xsim.bat tb_mrx -runall -testplusarg %1 -log xs.log > NUL 2>&1
if not exist resp.memh exit /b 1
exit /b 0
