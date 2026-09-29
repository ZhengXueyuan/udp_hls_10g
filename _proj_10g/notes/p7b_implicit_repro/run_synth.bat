@echo off
REM usage: run_synth.bat <case_name> <top_module>
REM caller must cd into the case directory first.
setlocal
set VB=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
set R=D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_implicit_repro
call "%VB%" -mode batch -source "%R%\synth_one.tcl" -nojournal -nolog -tclargs %1 %2 > synth_%1.log 2>&1
echo VIVADO_RC=%errorlevel%
endlocal
