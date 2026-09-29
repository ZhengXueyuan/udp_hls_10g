@echo off
REM F4 下游判别实验 runner.  usage: run_tb_f4_chain.bat [new|old]
REM   new (默认) = 修复后 RTL (+define F4_NEWPORTS);  old = 修复前副本 (变异对照)
setlocal
set MODE=%1
if "%MODE%"=="" set MODE=new
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set R=D:\repo\XCKU5PMini\udp_hls_10g
set RD=%~dp0rd_%MODE%
if not exist "%RD%" mkdir "%RD%"
cd /d "%RD%"
for %%F in (f5_data.memh f5_dv.memh f5_er.memh f5_wr.memh f5_frames.txt) do copy /Y "%~dp0%%F" "%%F" >NUL
if exist xsim.dir rmdir /s /q xsim.dir
if "%MODE%"=="mutS" (
  set DEFS=-d F4_NEWPORTS
  set MAC=%R%\sim\f4sim\mut_newbug\mac_rx_64.v %R%\sim\f4sim\mut_newbug\fifo_sync.v
) else if "%MODE%"=="mutcrs" (
  set DEFS=-d F4_NEWPORTS
  set MAC=%R%\sim\f4chain\mut_termcrs\mac_rx_64.v %R%\sim\f4chain\mut_termcrs\fifo_sync.v
) else if "%MODE%"=="old" (
  set DEFS=
  set MAC=%R%\sim\f4sim\prefix_rtl\mac_rx_64.v %R%\sim\f4sim\prefix_rtl\fifo_sync.v
) else (
  set DEFS=-d F4_NEWPORTS
  set MAC=%R%\rtl\mac_rx_64.v %R%\rtl\fifo_sync.v
)
call %XV%\xvlog.bat %DEFS% -work xil_defaultlib %MAC% ^
  %R%\rtl\crc32_8b.v %R%\rtl\vlan_strip.v %R%\rtl\rx_classify.v ^
  %R%\rtl\frame_fifo.v %R%\rtl\slow_rx_adp.v %R%\tb\tb_f4_chain.v > xv_c.log 2>&1 || (type xv_c.log & echo XVLOG-FAIL & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xv_c.log 2>&1
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xv_c.log >NUL && (echo IMPLICIT-DECL-FAIL & type xv_c.log & exit /b 1)
findstr /C:"10-3091" xv_c.log >NUL && (echo BITWIDTH-FAIL & type xv_c.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_f4_chain xil_defaultlib.glbl -s tb_f4c -log xe_c.log > NUL 2>&1 || (type xe_c.log & echo XELAB-FAIL & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_c.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xe_c.log & exit /b 1)
call %XV%\xsim.bat tb_f4c -runall -log xs_c.log > NUL 2>&1
type xs_c.log
exit /b 0
