@echo off
REM 无溢出路径逐位不变门: 同一份 NOSTALL 刺激 (sim\stim_*.memh) 分别跑 修复前/修复后 RTL,
REM 逐词比对 m_axis 交付流 (resp.memh) —— 词流必须完全一致 (字节流逐位不变的直接证据)。
setlocal
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set R=D:\repo\XCKU5PMini\udp_hls_10g
set T=%R%\sim\f4sim\bitx
set FAIL=0
for %%V in (old new) do (
  if not exist "%T%\%%V" mkdir "%T%\%%V"
  copy /Y "%R%\sim\stim_data.memh" "%T%\%%V\" >NUL
  copy /Y "%R%\sim\stim_dv.memh"   "%T%\%%V\" >NUL
  copy /Y "%R%\sim\stim_er.memh"   "%T%\%%V\" >NUL
  copy /Y "%R%\sim\run.tcl"        "%T%\%%V\" >NUL
)
call :one old "%R%\sim\f4sim\prefix_rtl\mac_rx_64.v" "%R%\sim\f4sim\prefix_rtl\fifo_sync.v" || exit /b 1
call :one new "%R%\rtl\mac_rx_64.v" "%R%\rtl\fifo_sync.v" || exit /b 1

REM --- 逐词比对 (先去 STATS 行) ---
findstr /V /C:"STATS" "%T%\old\resp.memh" > "%T%\old.words"
findstr /V /C:"STATS" "%T%\new\resp.memh" > "%T%\new.words"
fc /B "%T%\old.words" "%T%\new.words" > "%T%\fc.log" 2>&1
if errorlevel 1 (echo BITEXACT-RESULT: FAIL & type "%T%\fc.log" & exit /b 1)
for %%F in (old new) do (
  for /f "tokens=1-4" %%A in ('findstr /C:"STATS" "%T%\%%F\resp.memh"') do if not "%%A"=="STATS" echo %%A %%B %%C %%D
)
findstr /C:"STATS" "%T%\old\resp.memh"
findstr /C:"STATS" "%T%\new\resp.memh"
echo BITEXACT-RESULT: PASS (交付词流逐位相同)
exit /b 0

:one
setlocal
cd /d "%T%\%~1"
if exist xsim.dir rmdir /s /q xsim.dir
call "%XV%\xvlog.bat" -work xil_defaultlib %~2 %~3 "%R%\rtl\crc32_8b.v" "%R%\tb\tb_mac_rx_64.v" > xv.log 2>&1 || (type xv.log & exit /b 1)
call "%XV%\xelab.bat" -debug typical -timescale 1ns/1ps -L xil_defaultlib xil_defaultlib.tb_mac_rx_64 -s tb_snap -log xe.log > NUL 2>&1 || (type xe.log & exit /b 1)
call "%XV%\xsim.bat" tb_snap -tclbatch run.tcl -testplusarg NOSTALL -log xs.log > NUL 2>&1
endlocal
exit /b 0
