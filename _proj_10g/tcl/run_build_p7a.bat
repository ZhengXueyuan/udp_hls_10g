@echo off
REM run_build_p7a.bat -- P7a main bitstream build (10GBASE-R, 2 channels, SFP loop)
REM   From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\tcl\run_build_p7a.bat'
REM   Full stdout goes to ..\reports\p7a_build_stdout.txt (tracked; .txt is the gate log)
setlocal
cd /d %~dp0
set VIV="C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
call %VIV% -mode batch -source build_p7a.tcl -log ..\reports\p7a_build.log -journal ..\reports\p7a_build.jou > ..\reports\p7a_build_stdout.txt 2>&1
set RC=%ERRORLEVEL%
echo ---- vivado exit=%RC% ----
findstr /C:"ATOMIC_SET" /C:"MISMATCH" /C:"PROV_BAD" /C:"progress=" /C:"BITSTREAM" /C:"IS_LOCKED" /C:"12-4739" /C:"P7A_XDC" ..\reports\p7a_build_stdout.txt
exit /b %RC%
