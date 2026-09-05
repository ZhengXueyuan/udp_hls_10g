@echo off
REM xvlog_wp4b.bat -- P4b chain TB compile gate (HLS slow stack + RTL + board wrapper)
REM   regenerates hls_files.f from the current HLS syn/verilog dir (same pattern as
REM   run_tb_p4_chain.bat -- stale hls_files_new.f references deleted files and is
REM   missing current HLS units), propagates xvlog errors. Run from Git Bash:
REM   cmd //c D:\repo\ECO\udp_hls_10g\sim\p4sim\xvlog_wp4b.bat
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib ..\..\rtl\crc32_8b.v ..\..\rtl\fifo_sync.v ..\..\rtl\checksum16.v ..\..\rtl\frame_fifo.v ..\..\rtl\mac_rx_64.v ..\..\rtl\mac_tx_64.v ..\..\rtl\tcp_cam.v ..\..\rtl\tcb.v ..\..\rtl\tcp_rx.v ..\..\rtl\tcp_tx_frame.v ..\..\rtl\retx_ram.v ..\..\rtl\tcp_echo.v ..\..\rtl\rx_classify.v ..\..\rtl\slow_rx_adp.v ..\..\rtl\slow_tx_adp.v ..\..\rtl\slow_cfg_adp.v ..\..\rtl\tx_arb.v ..\..\board\util_gmii_to_rgmii.v --define XILINX_SIMULATOR ..\..\board\wrapper_p4.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
