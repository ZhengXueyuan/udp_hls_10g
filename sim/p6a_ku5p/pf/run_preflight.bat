@echo off
REM run_preflight.bat - KU5P (DEV_USP + APP_MODE) syntax/trap-24 preflight.
REM   Runs in its own dir so it does not fight other xsim runs over xsim.dir.
REM
REM ---- P7B FIX (file order + stale list): rtl/udp_echo.v and the HLS solution1
REM   udp_echo.v define the SAME module; whoever is analyzed LAST wins the library.
REM   This gate used to compile HLS first and then a hand-kept rtl_files.f that
REM   listed rtl\udp_echo.v, so the HAND-WRITTEN udp_echo (no AXIS ports) won and
REM   EVERY elaboration died with 19x 'ERROR: [VRFC 10-3180] cannot find port
REM   'ap_clk' / 'rx_stream_TDATA' ... [board/wrapper_p4.v:1906]'.  That list was
REM   also 4 files stale (fifo_async / snap_cdc / snap_seq / clk_gen_p6b -- the P6b
REM   additions).  Now: RTL first, HLS last, and both lists are generated exactly
REM   like the authoritative lints do it (board/run_lint_p6e.bat, sim/p6b_lint).
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
set HLS=%ROOT%\hls\slowstack_prj\solution1\syn\verilog
if exist hls_files.f del /q hls_files.f
(dir /b /s %HLS%\*.v) > hls_files.f
if exist rtl_files.f del /q rtl_files.f
(dir /b /s %ROOT%\rtl\*.v) > rtl_files.f
if exist pf.log del /q pf.log
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP -f rtl_files.f > pf.log 2>&1 || (type pf.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP %ROOT%\board\wrapper_p4.v %ROOT%\board\util_gmii_to_rgmii_us.v %ROOT%\board\util_gmii_to_rgmii.v %ROOT%\board\uart_dbg.v >> pf.log 2>&1 || (type pf.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP -f hls_files.f >> pf.log 2>&1 || (type pf.log & exit /b 1)
REM ---- trap-24 detection.  This gate used to PRINT ONLY (exit code stayed 0),
REM   i.e. a real defect produced a green run -- the dumb-gate form.
echo ---- implicit nets ----
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" pf.log && echo === IMPLICIT ===
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" pf.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" pf.log & exit /b 1)
echo ---- errors ----
findstr /I /C:"ERROR" pf.log && echo === ERROR ===
findstr /I /C:"ERROR" pf.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" pf.log & exit /b 1)
REM ---- xelab face (P7B): the PORT-CONNECTION form of trap 24 prints NOTHING in
REM   xvlog (exit 0, empty log).  Only possible now that the RTL/HLS order above is
REM   correct -- before the fix this elaboration could not even build a snapshot.
call %XV%\xvlog.bat -work xil_defaultlib -d APP_MODE -d DEV_USP "%XV%\..\data\verilog\src\glbl.v" >> pf.log 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s preflight -log xelab_pf.log > NUL 2>&1
if errorlevel 1 (echo XELAB-FAIL & type xelab_pf.log & exit /b 1)
REM   positive evidence: an empty/absent xelab log must NOT read as clean
findstr /C:"Built simulation snapshot" xelab_pf.log >NUL || (echo XELAB-NO-SNAPSHOT & type xelab_pf.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_pf.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_pf.log & exit /b 1)
echo ==== PREFLIGHT OK (xvlog + xelab clean) ====
