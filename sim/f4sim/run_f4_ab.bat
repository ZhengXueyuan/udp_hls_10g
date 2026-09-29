@echo off
REM F4 A/B 门: 同一份激励跑 修复前(prefix_rtl) / 修复后(my rtl), 逐例比 "好帧不被白丢"
REM usage: run_f4_ab.bat [rtl_dir_for_new]   默认 = ../../rtl
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set PY=C:\Users\zhxue\anaconda3\python.exe
set R=D:\repo\XCKU5PMini\udp_hls_10g
set NEWMODE=%1
if "%NEWMODE%"=="" set NEWMODE=new
call "%~dp0run_tb_f4_mac.bat" old > "%~dp0ab_old.log" 2>&1
call "%~dp0run_tb_f4_mac.bat" %NEWMODE% > "%~dp0ab_%NEWMODE%.log" 2>&1
%PY% "%R%\tools\f4_ab_check.py" "%~dp0rd_old\f4_case_stats.txt" "%~dp0rd_%NEWMODE%\f4_case_stats.txt"
if errorlevel 1 (echo F4-AB-RESULT: FAIL & exit /b 1)
echo F4-AB-RESULT: PASS
exit /b 0
