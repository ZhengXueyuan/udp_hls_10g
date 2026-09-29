@echo off
REM probe: can xelab elaborate the P6e lint source set? (timed, scratch only)
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set WORK=%~dp0probe_work
if exist "%WORK%" rmdir /s /q "%WORK%"
mkdir "%WORK%"
cd /d "%WORK%"
dir /b /s "%ROOT%\rtl\*.v" > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v >> files.f
echo %ROOT%\board\util_gmii_to_rgmii.v >> files.f
echo %ROOT%\board\uart_dbg.v >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v >> files.f
echo === XVLOG START %TIME% ===
call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -i %ROOT%\rtl -i %ROOT%\board -f files.f > xv_p6e.log 2>&1
echo XVLOG_RC=%ERRORLEVEL%
echo === XELAB START %TIME% ===
call %XV%\xelab.bat -L unisims_ver work.wrapper_p4 -s lintprobe --mt 4 > xe_p6e.log 2>&1
echo XELAB_RC=%ERRORLEVEL%
echo === xelab.log tail ===
type xe_p6e.log
echo === XELAB DONE %TIME% ===
