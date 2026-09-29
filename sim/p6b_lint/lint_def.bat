@echo off
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist xsim2.dir rmdir /s /q xsim2.dir
dir /b /s "%ROOT%\rtl\*.v"                                    > files_def.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files_def.f
echo %ROOT%\board\wrapper_p4.v                                >> files_def.f
echo %ROOT%\board\util_gmii_to_rgmii.v                        >> files_def.f
echo %ROOT%\board\uart_dbg.v                                  >> files_def.f
call %XV%\xvlog.bat -work xil_defaultlib2 -i %ROOT%\rtl -i %ROOT%\board -f files_def.f > xvlog_def.log 2>&1
echo ---- xvlog exit=%ERRORLEVEL% ----
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_def.log && echo === IMPLICIT ===
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_def.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_def.log & exit /b 1)
REM   This gate used to PRINT ONLY on every hit (no exit code), so a real trap-24
REM   defect produced exit 0 -- the dumb-gate form.  Same hard-fail idiom as
REM   board/run_lint_p6e.bat now.
REM   The BARE 10-3091 key is a measured false-positive weapon (14 benign unsized
REM   literals in board/util_gmii_to_rgmii.v) -- narrowed signature only.  xvlog does
REM   no width check at all (measured 0 hits in 869 xvlog logs), so width coverage
REM   comes from the xelab face below.
findstr /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" xvlog_def.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"VRFC 10-3091" xvlog_def.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_def.log && echo === ERROR ===
findstr /I /C:"ERROR" xvlog_def.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_def.log & exit /b 1)
echo XVLOG-DONE
REM
REM ---- P7B xelab face: the PORT-CONNECTION form of trap 24 is SILENT in xvlog,
REM   so this lint must also elaborate (same recipe as board/run_lint_p6e.bat).
REM ---- P7B xelab face (DEFAULT / K7 config: util_gmii_to_rgmii.v, no PCIE_OBS
REM   so there is no xdma_0 and no stub is needed).
call %XV%\xvlog.bat -work xil_defaultlib2 "%XV%\..\data\verilog\src\glbl.v" >> xvlog_def.log 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib2.wrapper_p4 xil_defaultlib2.glbl -s lint_def -log xelab_def.log > NUL 2>&1
if errorlevel 1 (echo XELAB-FAIL & type xelab_def.log & exit /b 1)
REM   positive evidence: an empty/absent xelab log must NOT read as clean
findstr /C:"Built simulation snapshot" xelab_def.log >NUL || (echo XELAB-NO-SNAPSHOT & type xelab_def.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_def.log && echo === IMPLICIT-XELAB ===
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_def.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_def.log & exit /b 1)
echo XELAB-LINT-OK: xelab face ran, log = xelab_def.log
