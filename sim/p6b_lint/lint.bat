@echo off
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim.dir rmdir /s /q xsim.dir
dir /b /s "%ROOT%\rtl\*.v"                                    > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v                                >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                     >> files.f
echo %ROOT%\board\uart_dbg.v                                  >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                         >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -d DP_156MHZ -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_lint.log 2>&1
findstr /I /C:"implicitly" xvlog_lint.log && echo === IMPLICIT ===
findstr /C:"10-3091" xvlog_lint.log && echo === BITWIDTH ===
findstr /I /C:"ERROR" xvlog_lint.log && echo === ERROR ===
echo XVLOG-DONE
