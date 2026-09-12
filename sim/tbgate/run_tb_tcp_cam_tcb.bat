@echo off
REM run_tb_tcp_cam_tcb.bat - tcb regression (only appended conn0 dbg_* outputs)
REM Run from Git Bash:
REM   cmd //c D:\repo\ECO\udp_hls_10g\sim\tbgate\run_tb_tcp_cam_tcb.bat
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call %XV%\xvlog.bat -work xil_defaultlib ..\..\rtl\tcp_cam.v ..\..\rtl\tcb.v ..\..\tb\tb_tcp_cam_tcb.v > xvlog_tcb.log 2>&1 || (type xvlog_tcb.log & exit /b 1)
call %XV%\xelab.bat -debug typical xil_defaultlib.tb_tcp_cam_tcb -s tb_tcp_cam_tcb -log xelab_tcb.log > NUL 2>&1 || (type xelab_tcb.log & exit /b 1)
call %XV%\xsim.bat tb_tcp_cam_tcb -runall -log xsim_tcb.log > NUL 2>&1 || (type xsim_tcb.log & exit /b 1)
