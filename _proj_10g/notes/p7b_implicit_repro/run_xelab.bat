@echo off
REM usage: run_xelab.bat <top_module> <logname>
REM caller must cd into the case directory first.
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
call "%XV%\xelab.bat" %1 -s %~2_sim > %~2.log 2>&1
echo XELAB_RC=%errorlevel%
endlocal
