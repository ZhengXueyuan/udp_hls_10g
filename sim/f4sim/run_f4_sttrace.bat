@echo off
REM 短帧帧尾决策拍轨迹 (调试用): run_f4_sttrace.bat [old|mut|new]
setlocal
set MODE=%1
if "%MODE%"=="" set MODE=new
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set R=D:\repo\XCKU5PMini\udp_hls_10g
set RD=%~dp0st_%MODE%
if not exist "%RD%" mkdir "%RD%"
cd /d "%RD%"
for %%F in (f4_data.memh f4_dv.memh f4_er.memh f4_wr.memh f4_cases.txt) do copy /Y "%~dp0%%F" "%%F" >NUL
if exist xsim.dir rmdir /s /q xsim.dir
if "%MODE%"=="old" (
  set DUT=%R%\sim\f4sim\prefix_rtl\mac_rx_64.v %R%\sim\f4sim\prefix_rtl\fifo_sync.v
) else if "%MODE%"=="mut" (
  set DUT=%R%\sim\f4sim\mut_newbug\mac_rx_64.v %R%\sim\f4sim\mut_newbug\fifo_sync.v
) else (
  set DUT=%R%\rtl\mac_rx_64.v %R%\rtl\fifo_sync.v
)
call %XV%\xvlog.bat -d F4_NEWPORTS -d F4_STTRACE -work xil_defaultlib %DUT% %R%\rtl\crc32_8b.v %R%\tb\tb_mac_rx_f4.v > xv.log 2>&1 || (type xv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv.log 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_mac_rx_f4 xil_defaultlib.glbl -s tb_f4 -log xe.log > NUL 2>&1 || (type xe.log & exit /b 1)
call %XV%\xsim.bat tb_f4 -runall -log xs.log > NUL 2>&1
exit /b 0
