@echo off
REM =====================================================================
REM run_mut.bat -- 反例门 (判别力): 乒乓退化单 bank ⇒ 拍/帧判据必须变红
REM   变异体 = mut_single_bank\udp_tx_frame.v (由 mk_mut.py 生成, 只改 1 处)
REM   期望: tb_rate_frame 拍/帧从 191 回到 ~378 (判据红),
REM         同时 tb_ovl_eq 的**逐字节输出仍与默认一致** ⇒ 判别的是速率不是内容。
REM =====================================================================
setlocal
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "RTL=%ROOT%\rtl"
set "PY=C:\Users\zhxue\anaconda3\python.exe"
"%PY%" "%HERE%\mk_mut.py" || exit /b 1
cd /d "%HERE%\run_mut"
if exist xsim.dir rmdir /s /q xsim.dir
del /q xsim_f.log xsim_e.log 2>NUL
call "%XV%\xvlog.bat" -work xil_defaultlib -d UDP_TX_OVL "%RTL%\fifo_sync.v" "%RTL%\checksum16.v" ^
  "%HERE%\mut_single_bank\udp_tx_frame.v" "%RTL%\tx_arb.v" ^
  "%ROOT%\_proj_10g\p7b_mac\rtl\crc32_64.v" "%ROOT%\_proj_10g\p7b_mac\rtl\mac_tx_10g.v" ^
  "%HERE%\tb_rate_frame.v" "%HERE%\tb_rate_chain.v" > xvlog_tb.log 2>&1 || (type xvlog_tb.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_lvl_frame -s tb_lvl_frame -log xelab_f.log > NUL 2>&1 || (type xelab_f.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical xil_defaultlib.tb_rate_chain -s tb_rate_chain -log xelab_c.log > NUL 2>&1 || (type xelab_c.log & exit /b 1)
call "%XV%\xsim.bat" tb_lvl_frame -runall > NUL 2>&1
if exist xsim.log del /q xsim_f.log 2>NUL
if exist xsim.log ren xsim.log xsim_f.log
call "%XV%\xsim.bat" tb_rate_chain -runall > NUL 2>&1
if exist xsim.log del /q xsim_c.log 2>NUL
if exist xsim.log ren xsim.log xsim_c.log
echo ---- MUTANT (乒乓退化单 bank): tb_rate_frame ----
findstr /C:"frames measured" /C:"MEAN FRAME" /C:"PAYLOAD RATE" xsim_f.log
echo ---- MUTANT: tb_rate_chain ----
findstr /C:"XGMII frames" /C:"MEAN FRAME" /C:"PAYLOAD RATE" xsim_c.log
echo.
REM 判据变红检查: 拍/帧必须 >= 300 (不重叠) 而不是 191
findstr /C:"MEAN FRAME PERIOD   = 3" xsim_f.log > NUL
if errorlevel 1 (echo [MUT-GATE FAIL] 变异体拍/帧没有被判据抓住 -- 判据无判别力 & exit /b 1)
echo [MUT-GATE OK] 变异体拍/帧回到 ~378 ⇒ 拍/帧判据抓住"乒乓被禁用"
exit /b 0
