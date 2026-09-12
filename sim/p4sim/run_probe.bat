@echo off
cd /d %~dp0
if exist txdrop.memh del /q txdrop.memh
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > /dev/null 2>&1
call %XV%\xvlog.bat -work xil_defaultlib D:\repo\ECO\udp_hls_10g\rtl\crc32_8b.v D:\repo\ECO\udp_hls_10g\rtl\fifo_sync.v D:\repo\ECO\udp_hls_10g\rtl\checksum16.v D:\repo\ECO\udp_hls_10g\rtl\frame_fifo.v D:\repo\ECO\udp_hls_10g\rtl\mac_rx_64.v D:\repo\ECO\udp_hls_10g\rtl\mac_tx_64.v D:\repo\ECO\udp_hls_10g\rtl\tcp_cam.v D:\repo\ECO\udp_hls_10g\rtl\tcb.v D:\repo\ECO\udp_hls_10g\rtl\tcp_rx.v D:\repo\ECO\udp_hls_10g\rtl\tcp_tx_frame.v D:\repo\ECO\udp_hls_10g\rtl\retx_ram.v D:\repo\ECO\udp_hls_10g\rtl\tcp_echo.v D:\repo\ECO\udp_hls_10g\rtl\axis_pipe.v D:\repo\ECO\udp_hls_10g\rtl\tcp_synp.v D:\repo\ECO\udp_hls_10g\rtl\rx_classify.v D:\repo\ECO\udp_hls_10g\rtl\slow_rx_adp.v D:\repo\ECO\udp_hls_10g\rtl\slow_tx_adp.v D:\repo\ECO\udp_hls_10g\rtl\tx_arb.v D:\repo\ECO\udp_hls_10g\tb\tb_p4_chain.v > /dev/null 2>&1 || (echo XVLOG_FAIL & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p4_chain xil_defaultlib.glbl -s tb_probe -log xelab_probe.log > /dev/null 2>&1 || (echo XELAB_FAIL & exit /b 1)

call %XV%\xsim.bat tb_probe -runall -log xsim_probe.log > /dev/null 2>&1 || (echo XSIM_FAIL & exit /b 1)
echo PROBE_DONE
