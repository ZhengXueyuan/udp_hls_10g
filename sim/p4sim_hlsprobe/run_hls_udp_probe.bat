@echo off
REM run_hls_udp_probe.bat — HLS 孤立探针 (直喂 ARP+UDP, 查 udp echo 载荷污染)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog

copy /y %HLS%\*.dat . >nul
(if exist %HLS%\ (dir /b /s %HLS%\*.v) else (echo HLS dir missing & exit /b 1)) > hls_files.f

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_hls_udp_probe.py D:\repo\ECO\udp_hls_10g\sim\p4sim_hlsprobe || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib D:\repo\ECO\udp_hls_10g\tb\tb_hls_udp_probe.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical xil_defaultlib.tb_hls_udp_probe -s tb_hls_udp_probe -log xelab_run.log > NUL 2>&1 || (type xelab_run.log & exit /b 1)
call %XV%\xsim.bat tb_hls_udp_probe -runall -log xsim_run.log > NUL 2>&1 || (type xsim_run.log & exit /b 1)

%PY% D:\repo\ECO\udp_hls_10g\tools\gen_hls_udp_probe.py D:\repo\ECO\udp_hls_10g\sim\p4sim_hlsprobe check
