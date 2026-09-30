@echo off
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d "%~dp0"
set R=%~dp0..\..\..\..\..\rtl
if exist xsim.dir rmdir /s /q xsim.dir
call %XV%\xvlog.bat -work xil_defaultlib -d P7B_10G "%R%\fifo_sync.v" "%R%\frame_fifo.v" "%R%\checksum16.v" "%R%\udp_rx.v" "%R%\udp_split.v" "%R%\slow_rx_adp.v" "%R%\udp_tx_cfg.v" "%R%\udp_tx_frame.v" "%R%\tx_arb.v" "%R%\app_udp_pattern.v" "%~dp0..\tb_app_udp_tagged.v" > t_xv.log 2>&1 || (type t_xv.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> t_xv.log 2>&1 || (type t_xv.log & exit /b 1)
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_app_udp xil_defaultlib.glbl -s tb_app_udp -log t_xe.log > NUL 2>&1 || (type t_xe.log & exit /b 1)
call %XV%\xsim.bat tb_app_udp -runall -log t_xs.log > NUL 2>&1
findstr /C:"CHK_" /C:"P5E UDP APP GATE" t_xs.log
echo TAG-DONE
