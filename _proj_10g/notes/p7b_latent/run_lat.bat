@echo off
rem ==========================================================================
rem P7B latent-FIFO closeout bench: counterexample double-run
rem   (same bench; the only difference between runs is the RTL under test)
rem   usage: cmd //c 'run_lat.bat'   (from git bash) or run_lat.bat in cmd
rem   NOTE: instance-2 config is fed through lat_of_cfg.txt ("np nb free"),
rem         not via -testplusarg: xsim 2025.2 refuses a plusarg carrying an
rem         '=' sign and also refuses a second -testplusarg on the same line.
rem ==========================================================================
setlocal
set "VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin"
set "HERE=%~dp0"
set "ROOT=%~dp0..\..\.."
pushd "%HERE%"
del /q lat_wf_out.txt lat_of_out.txt 2>nul
rmdir /s /q xsim.dir 2>nul

call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib "%ROOT%\rtl\fifo_sync.v" "%ROOT%\rtl\frame_fifo.v" "%ROOT%\rtl\slow_tx_adp.v" "%ROOT%\rtl\slow_rx_adp.v" "%HERE%tb_lat_wf.v" "%HERE%tb_lat_of.v" > xvlog_lat.log 2>&1
if errorlevel 1 (type xvlog_lat.log & exit /b 1)
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib "%VIV_BIN%\..\..\data\verilog\src\glbl.v" >> xvlog_lat.log 2>&1
if errorlevel 1 (type xvlog_lat.log & exit /b 1)

call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L unisims_ver -L xil_defaultlib xil_defaultlib.tb_lat_wf xil_defaultlib.glbl -s tb_lat_wf -log xelab_lat_wf.log > NUL 2>&1
if errorlevel 1 (type xelab_lat_wf.log & exit /b 1)
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L unisims_ver -L xil_defaultlib xil_defaultlib.tb_lat_of xil_defaultlib.glbl -s tb_lat_of -log xelab_lat_of.log > NUL 2>&1
if errorlevel 1 (type xelab_lat_of.log & exit /b 1)

echo --- tb_lat_wf (instance 1: slow_tx_adp u_wf) ---
call "%VIV_BIN%\xsim.bat" tb_lat_wf -runall -log xsim_lat_wf.log > NUL 2>&1
findstr /C:"RESULT" /C:"J1 " /C:"J2 " /C:"J3 " /C:"TB_LAT_WF" xsim_lat_wf.log

echo --- tb_lat_of cfg "2100 7 0" (instance 2: slow_rx_adp u_ofifo, over threshold) ---
> lat_of_cfg.txt echo 2100 7 0
call "%VIV_BIN%\xsim.bat" tb_lat_of -runall -log xsim_lat_of_a.log > NUL 2>&1
findstr /C:"CFG" /C:"RESULT" /C:"PROBE" /C:"TB_LAT_OF" xsim_lat_of_a.log

echo --- tb_lat_of cfg "1400 8 0" (negative control: under threshold) ---
> lat_of_cfg.txt echo 1400 8 0
call "%VIV_BIN%\xsim.bat" tb_lat_of -runall -log xsim_lat_of_b.log > NUL 2>&1
findstr /C:"CFG" /C:"RESULT" /C:"PROBE" /C:"TB_LAT_OF" xsim_lat_of_b.log

echo --- tb_lat_of cfg "2100 7 1" (negative control: reader never starved) ---
> lat_of_cfg.txt echo 2100 7 1
call "%VIV_BIN%\xsim.bat" tb_lat_of -runall -log xsim_lat_of_c.log > NUL 2>&1
findstr /C:"CFG" /C:"RESULT" /C:"PROBE" /C:"TB_LAT_OF" xsim_lat_of_c.log

del /q lat_of_cfg.txt 2>nul
popd
endlocal
