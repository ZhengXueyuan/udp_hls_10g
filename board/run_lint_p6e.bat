@echo off
REM run_lint_p6e.bat -- fast elaboration lint for the P6e build config BEFORE the real build
REM   Checks (hard failures): implicit nets, bit-width mismatch, any xvlog ERROR.
REM   Rationale: a full P6e build takes ~30 min (XDMA + place/route); xvlog catches the
REM   whole class of "ifdefd branch has a typo / wire used before declared / an 8-word
REM   concat that is really 9 words" in seconds. Run this after EVERY rtl edit.
REM   NOTE: cmd does not glob *.v -- the file list is generated into lint_p6e\files.f
REM   from Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_lint_p6e.bat'
setlocal
cd /d %~dp0
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=D:\repo\XCKU5PMini\udp_hls_10g
if exist lint_p6e rmdir /s /q lint_p6e
mkdir lint_p6e
cd lint_p6e
dir /b /s "%ROOT%\rtl\*.v"                                  > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v                              >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                   >> files.f
echo %ROOT%\board\util_gmii_to_rgmii.v                      >> files.f
echo %ROOT%\board\uart_dbg.v                                >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                       >> files.f
echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v                >> files.f
call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_p6e.log 2>&1
echo ---- xvlog exit=%ERRORLEVEL% ----
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p6e.log >NUL && (echo IMPLICIT-DECL-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_p6e.log & exit /b 1)
findstr /C:"10-3091" xvlog_p6e.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & findstr /C:"10-3091" xvlog_p6e.log & exit /b 1)
findstr /I /C:"ERROR" xvlog_p6e.log >NUL && (echo XVLOG-ERROR-FAIL & findstr /I /C:"ERROR" xvlog_p6e.log & exit /b 1)
REM
REM ---- xelab face (P7B): the PORT-CONNECTION form of trap 24 prints NOTHING in
REM   xvlog (exit 0, empty log) -- xelab is the only detector for it.  xdma_0 is a
REM   Block-Design module with no RTL on disk, so the same sim stub the P6e gate
REM   uses is compiled in.  Measured ~12 s end to end (run_matrix is unaffected).
call %XV%\xvlog.bat -d PCIE_OBS -d DEV_USP -d APP_MODE -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_p6e.log 2>&1
call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.wrapper_p4 xil_defaultlib.glbl -s lint_p6e -log xelab_p6e.log > NUL 2>&1
if errorlevel 1 (echo XELAB-FAIL & type xelab_p6e.log & exit /b 1)
REM   positive evidence: an empty/absent xelab log must NOT read as clean
findstr /C:"Built simulation snapshot" xelab_p6e.log >NUL || (echo XELAB-NO-SNAPSHOT & type xelab_p6e.log & exit /b 1)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p6e.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_p6e.log & exit /b 1)
echo LINT-OK: no implicit nets, no width mismatch, no errors
