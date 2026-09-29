@echo off
REM 既有 mac_rx_64 门的回归 (路径指向本副本; 原 sim\run_tb.bat 指 ECO 副本)
REM usage: run_tb_mac_f4regress.bat NOSTALL|STALL|STALL2
setlocal
set MODE=%1
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set R=D:\repo\XCKU5PMini\udp_hls_10g
cd /d %R%\sim
if exist xsim.dir rmdir /s /q xsim.dir
if "%MODE%"=="STALL2" (set LEN=--lenient) else (set LEN=)
call "%XV%\xvlog.bat" -work xil_defaultlib %R%\rtl\crc32_8b.v %R%\rtl\fifo_sync.v %R%\rtl\mac_rx_64.v %R%\tb\tb_mac_rx_64.v > xv_mac_%MODE%.log 2>&1 || (type xv_mac_%MODE%.log & echo XVLOG-FAIL & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_mac_%MODE%.log >NUL && (echo IMPLICIT-DECL-FAIL & type xv_mac_%MODE%.log & exit /b 1)
findstr /C:"10-3091" xv_mac_%MODE%.log >NUL && (echo BITWIDTH-FAIL & type xv_mac_%MODE%.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_mac_rx_64 -s tb_snap -log xe_mac_%MODE%.log > NUL 2>&1 || (type xe_mac_%MODE%.log & echo XELAB-FAIL & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_mac_%MODE%.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_mac_%MODE%.log & exit /b 1)
call "%XV%\xsim.bat" tb_snap -tclbatch run.tcl -testplusarg %MODE% -log xs_mac_%MODE%.log > NUL 2>&1
type xs_mac_%MODE%.log
%PY% %R%\tools\parse_mac_rx.py %R%\sim %LEN% mac_%MODE%
if errorlevel 1 (echo MAC-%MODE%-RESULT: FAIL & exit /b 1)
echo MAC-%MODE%-RESULT: PASS
exit /b 0
