@echo off
REM ===========================================================================
REM run_tb_biz_win.bat -- P7B-BIZ per-word readback gate for the snapshot window
REM   DUT: _proj_pcie/rtl/axi_regs.v with SNAP_NW=57 (the wrapper's SNAP_NW_P6E).
REM   TB : _proj_10g/notes/p7b_biz_win/tb_biz_win.v
REM   Hard failures: implicit nets / bit-width mismatch keys (see CLAUDE.md #24).
REM   ASCII-only comments on purpose (project rule for .bat).
REM ===========================================================================
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set ROOT=%~dp0..\..\..
set RTL=%ROOT%\_proj_pcie\rtl\axi_regs.v
set TB=%~dp0tb_biz_win.v
cd /d %~dp0
if not exist "%RTL%" ( echo [PATHGUARD FAIL] no axi_regs.v & exit /b 90 )
if not exist "%TB%"  ( echo [PATHGUARD FAIL] no tb_biz_win.v & exit /b 90 )
if not exist "%XV%\xvlog.bat" ( echo [TOOL FAIL] no xvlog.bat & exit /b 91 )
findstr /C:"SNAP_NW_P6E = 61" "%ROOT%\board\wrapper_p4.v" >NUL || ( echo [FINGERPRINT FAIL] wrapper is not 61-word & exit /b 92 )

call "%XV%\xvlog.bat" -work xil_defaultlib "%RTL%" "%TB%" > xvlog_biz.log 2>&1 || ( type xvlog_biz.log & exit /b 1 )
call "%XV%\xvlog.bat" -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_biz.log 2>&1
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_biz.log >NUL && (echo IMPLICIT-DECL-FAIL & type xvlog_biz.log & exit /b 1)

call "%XV%\xelab.bat" -debug typical -L unisims_ver xil_defaultlib.tb_biz_win xil_defaultlib.glbl -s tb_biz_win -log xelab_biz.log > NUL 2>&1 || ( type xelab_biz.log & exit /b 1 )
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_biz.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & type xelab_biz.log & exit /b 1 )

call "%XV%\xsim.bat" tb_biz_win -runall -log xsim_biz.log > NUL 2>&1
type xsim_biz.log | findstr /C:"[FAIL]" /C:"PASS_ALL" /C:"FAIL      "
findstr /C:"PASS_ALL" xsim_biz.log >NUL || ( echo TB_BIZ_WIN_FAIL & exit /b 1 )
echo TB_BIZ_WIN_PASS
exit /b 0
