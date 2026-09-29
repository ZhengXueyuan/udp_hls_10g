@echo off
REM probe2: xelab wrapper_p4 with the xdma_0 sim stub (P6e lint config), timed
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set WORK=%~dp0probe2_work
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%"
cd /d "%WORK%"
dir /b /s "%ROOT%\rtl\*.v" > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v >> files.f
echo %ROOT%\board\uart_dbg.v >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v >> files.f
echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v >> files.f
echo === XVLOG %TIME% ===
call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -i %ROOT%\rtl -i %ROOT%\board -f files.f > xv_p6.log 2>&1
echo XVLOG_RC=%ERRORLEVEL%
call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv_p6.log 2>&1
echo GLBL_RC=%ERRORLEVEL%
echo === XELAB %TIME% ===
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s lintprobe -log xe_p6.log > NUL 2>&1
echo XELAB_RC=%ERRORLEVEL%
echo === XELAB %TIME% ===
type xe_p6.log
