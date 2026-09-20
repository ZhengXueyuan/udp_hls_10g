@echo off
REM P5d-D6: exp2 slot-leak TB (verbatim copy of sim/p5dx/exp2/tb_hls_slotleak.v)
REM run against the CANONICAL HLS netlist hls\slowstack_prj\solution1\syn\verilog.
REM Own dir keeps xsim.dir locks out of sim/p5dx/exp2 (other agents).
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set HLS=D:\repo\ECO\udp_hls_10g\hls\slowstack_prj\solution1\syn\verilog
set TB=D:\repo\ECO\udp_hls_10g\sim\p5dx_d6

if not exist "%HLS%\udp_echo.v" (echo HLS netlist missing & exit /b 1)
dir /b /s %HLS%\*.v > hls_files.f
copy /y %HLS%\*.dat %TB%\ >NUL

%PY% %TB%\gen_frames.py %TB% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -f hls_files.f > xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_hls.log 2>&1 || (type xvlog_hls.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib %TB%\tb_hls_slotleak.v > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_hls_slotleak xil_defaultlib.glbl -s tb_hls_slotleak -log xelab_d6.log > NUL 2>&1 || (type xelab_d6.log & exit /b 1)
call %XV%\xsim.bat tb_hls_slotleak -runall -log xsim_d6.log > NUL 2>&1 || (type xsim_d6.log & exit /b 1)

%PY% %TB%\check_exp2.py %TB%
exit /b %ERRORLEVEL%
