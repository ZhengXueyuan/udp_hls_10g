@echo off
REM P5d-D6: exp2 slot-leak TB (verbatim copy of sim/p5dx/exp2/tb_d6_counter.v)
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
call %XV%\xvlog.bat -work xil_defaultlib %TB%\tb_d6_counter.v > xvlog_ctr.log 2>&1 || (type xvlog_ctr.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_d6_counter xil_defaultlib.glbl -s tb_d6_counter -log xelab_ctr.log > NUL 2>&1 || (type xelab_ctr.log & exit /b 1)
call %XV%\xsim.bat tb_d6_counter -runall -log xsim_ctr.log > NUL 2>&1 || (type xsim_ctr.log & exit /b 1)

echo done
exit /b %ERRORLEVEL%
