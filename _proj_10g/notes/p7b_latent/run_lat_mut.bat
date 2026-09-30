@echo off
rem ==========================================================================
rem P7B latent-FIFO closeout bench: MUTATION negative control
rem   Same bench as run_lat.bat, but slow_tx_adp/slow_rx_adp are taken from
rem   .\mut\ with the write gate reverted to the same-cycle `full`
rem   (full_next -> full) -- i.e. exactly the pre-fix judgement.
rem   EXPECTED (this is the point): both instances FAIL again AND the new
rem   self-check counters (stat_fifo_ovf) read NON-ZERO => the counters have
rem   teeth (they are structurally 0 only while the gate is exact).
rem   usage: cmd //c 'run_lat_mut.bat'
rem ==========================================================================
setlocal
set "VIV_BIN=C:\AMDDesignTools\2025.2\Vivado\bin"
set "HERE=%~dp0"
set "ROOT=%~dp0..\..\.."
pushd "%HERE%"
del /q lat_wf_out.txt lat_of_out.txt 2>nul
rmdir /s /q xsim.dir 2>nul

call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib "%ROOT%\rtl\fifo_sync.v" "%ROOT%\rtl\frame_fifo.v" "%HERE%mut\slow_tx_adp.v" "%HERE%mut\slow_rx_adp.v" "%HERE%tb_lat_wf.v" "%HERE%tb_lat_of.v" > xvlog_mut.log 2>&1
if errorlevel 1 (type xvlog_mut.log & exit /b 1)
call "%VIV_BIN%\xvlog.bat" -work xil_defaultlib "%VIV_BIN%\..\..\data\verilog\src\glbl.v" >> xvlog_mut.log 2>&1
if errorlevel 1 (type xvlog_mut.log & exit /b 1)

call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L unisims_ver -L xil_defaultlib xil_defaultlib.tb_lat_wf xil_defaultlib.glbl -s tb_lat_wf -log xelab_mut_wf.log > NUL 2>&1
if errorlevel 1 (type xelab_mut_wf.log & exit /b 1)
call "%VIV_BIN%\xelab.bat" -debug typical -timescale 1ns/1ps -L unisims_ver -L xil_defaultlib xil_defaultlib.tb_lat_of xil_defaultlib.glbl -s tb_lat_of -log xelab_mut_of.log > NUL 2>&1
if errorlevel 1 (type xelab_mut_of.log & exit /b 1)

echo --- MUT tb_lat_wf (gate reverted to same-cycle full) ---
call "%VIV_BIN%\xsim.bat" tb_lat_wf -runall -log xsim_mut_wf.log > NUL 2>&1
findstr /C:"RESULT" /C:"PROBE" /C:"J1 " /C:"J2 " /C:"J3 " /C:"TB_LAT_WF" xsim_mut_wf.log

echo --- MUT tb_lat_of cfg "2100 7 0" (phase aligned, 1 byte lost) ---
> lat_of_cfg.txt echo 2100 7 0
call "%VIV_BIN%\xsim.bat" tb_lat_of -runall -log xsim_mut_of.log > NUL 2>&1
findstr /C:"CFG" /C:"RESULT" /C:"PROBE" /C:"TB_LAT_OF" xsim_mut_of.log

echo --- MUT tb_lat_of cfg "3008 8 0" (PHASE control: reaches full 2048 yet loses NOTHING) ---
> lat_of_cfg.txt echo 3008 8 0
call "%VIV_BIN%\xsim.bat" tb_lat_of -runall -log xsim_mut_of_b8.log > NUL 2>&1
findstr /C:"CFG" /C:"RESULT" /C:"PROBE" /C:"TB_LAT_OF" xsim_mut_of_b8.log

del /q lat_of_cfg.txt 2>nul
popd
endlocal
