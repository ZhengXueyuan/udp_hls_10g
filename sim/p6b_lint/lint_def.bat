@echo off
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim2.dir rmdir /s /q xsim2.dir
dir /b /s "%ROOT%\rtl\*.v"                                    > files_def.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files_def.f
echo %ROOT%\board\wrapper_p4.v                                >> files_def.f
echo %ROOT%\board\util_gmii_to_rgmii.v                        >> files_def.f
echo %ROOT%\board\uart_dbg.v                                  >> files_def.f
call %XV%\xvlog.bat -work xil_defaultlib2 -i %ROOT%\rtl -i %ROOT%\board -f files_def.f > xvlog_def.log 2>&1
findstr /I /C:"implicitly" xvlog_def.log && echo === IMPLICIT ===
findstr /C:"10-3091" xvlog_def.log && echo === BITWIDTH ===
findstr /I /C:"ERROR" xvlog_def.log && echo === ERROR ===
echo XVLOG-DEF-DONE
