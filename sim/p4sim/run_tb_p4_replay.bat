@echo off
REM run_tb_p4_replay.bat -- P4b-7-P6: p4b7_syn.pcapng PC->FPGA 流精确重放 (xsim)
REM   刺激由 tools/gen_stim_p4b7.py 预生成 (stim_data/dv/er.memh + cfg_tcb.memh),
REM   本 bat 只负责编译 (RTOLIM_FAST) + xsim 运行。
REM   %1 = NOPCACK (缺省 +PCACK); %2 = 运行日志名 (默认 xsim_run.log)
REM   用法 (Git Bash): cmd //c 'D:\...\run_tb_p4_replay.bat NOPCACK xsim_runa.log'
cd /d %~dp0
if exist txdrop.memh del /q txdrop.memh
REM P4e: delete vlan.memh so this gate never inherits VLAN tagging from a
REM previous run_tb_p4_*_vlan.bat (gen_stim/apply both read that file).
if exist vlan.memh del /q vlan.memh
REM P1-2: the slow-peer gate leaves pcslow.memh behind -- delete it so this
REM gate runs with the default fast-peer model.
if exist pcslow.memh del /q pcslow.memh
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog
set XPA=-testplusarg PCACK
if "%1"=="NOPCACK" set XPA=
set RUNLOG=%2
if "%RUNLOG%"=="" set RUNLOG=xsim_run.log

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d RTOLIM_FAST ^
  D:\repo\ECO\udp_hls_10g\rtl\crc32_8b.v ^
  D:\repo\ECO\udp_hls_10g\rtl\fifo_sync.v ^
  D:\repo\ECO\udp_hls_10g\rtl\checksum16.v ^
  D:\repo\ECO\udp_hls_10g\rtl\frame_fifo.v ^
  D:\repo\ECO\udp_hls_10g\rtl\mac_rx_64.v ^
  D:\repo\ECO\udp_hls_10g\rtl\mac_tx_64.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcp_cam.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcb.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcp_rx.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcp_tx_frame.v ^
  D:\repo\ECO\udp_hls_10g\rtl\retx_ram.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tcp_echo.v ^
  D:\repo\ECO\udp_hls_10g\rtl\axis_pipe.v ^
  D:\repo\ECO\udp_hls_10g\rtl\rx_classify.v ^
  D:\repo\ECO\udp_hls_10g\rtl\vlan_strip.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_rx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_cfg_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\slow_tx_adp.v ^
  D:\repo\ECO\udp_hls_10g\rtl\tx_arb.v ^
  D:\repo\ECO\udp_hls_10g\tb\tb_p4_chain.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_p4_chain -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_p4_chain -runall %XPA% -log %RUNLOG% > NUL 2>&1 || (type %RUNLOG% & exit /b 1)
