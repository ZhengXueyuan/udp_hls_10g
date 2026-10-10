@echo off
REM =====================================================================
REM run_xvlog_4combo.bat -- P7B build F: xvlog gate for `board/wrapper_p4.v`
REM   under the **4 macro combinations** of `DP_156MHZ` x `PCIE_OBS`
REM   (CLAUDE.md "latent design debt": both macros can be enabled
REM    independently, so all four combinations must compile).
REM   Hard-fail contract per combination (same idiom as
REM   board/run_lint_p6e.bat / sim/p6b_lint/lint.bat):
REM     1) xvlog rc != 0  (or any ERROR line)                    => FAIL
REM     2) implicit-net 5-key table hit (NOT the bare 10-3091,
REM        which is a measured false-positive weapon)            => FAIL
REM   NOTE: no `-d P7B_10G` / `-d APP_MODE` here -- those macros change the
REM   FILE LIST itself (PCS IP / HLS slow path) and are covered by other
REM   gates (p7b_chain / p7b_appsplit). This gate only answers:
REM   "does wrapper_p4.v compile cleanly, with no implicit nets, in all 4".
REM =====================================================================
setlocal
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "ROOT=%HERE%\..\..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\CLAUDE.md" (echo [PATHGUARD FAIL] %ROOT% & exit /b 1)
set "XV=C:\AMDDesignTools\2025.2\Vivado\bin"
set "W=%HERE%\xvlog4"
if exist "%W%" rmdir /s /q "%W%"
mkdir "%W%"
cd /d "%W%"
dir /b /s "%ROOT%\rtl\*.v"                                    > files.f
dir /b /s "%ROOT%\hls\slowstack_prj\solution1\syn\verilog\*.v" >> files.f
echo %ROOT%\board\wrapper_p4.v                                >> files.f
echo %ROOT%\board\util_gmii_to_rgmii_us.v                     >> files.f
echo %ROOT%\board\util_gmii_to_rgmii.v                        >> files.f
echo %ROOT%\board\uart_dbg.v                                  >> files.f
echo %ROOT%\_proj_pcie\rtl\axi_regs.v                         >> files.f
echo %ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v                    >> files.f

set "FAILS=0"
REM base = production macros APP_MODE + DEV_USP (same as board/run_lint_p6e.bat);
REM the 4 combinations below are DP_156MHZ x PCIE_OBS on top of that base.
set "BASE=-d APP_MODE -d DEV_USP"
call :combo c1 "%BASE%"
call :combo c2 "%BASE% -d DP_156MHZ"
call :combo c3 "%BASE% -d PCIE_OBS"
call :combo c4 "%BASE% -d PCIE_OBS -d DP_156MHZ"

echo ==================== SUMMARY ====================
if "%FAILS%"=="0" (echo XVLOG_4COMBO: PASS & exit /b 0)
echo XVLOG_4COMBO: FAIL count=%FAILS%
exit /b 1

:combo
set "NAME=%~1"
set "DEFS=%~2"
if not exist "%NAME%" mkdir "%NAME%"
call "%XV%\xvlog.bat" -work xil_defaultlib %DEFS% -i "%ROOT%\rtl" -i "%ROOT%\board" -f files.f > "%NAME%\xvlog.log" 2>&1
set "RC=%errorlevel%"
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" "%NAME%\xvlog.log" >NUL
set "IMP=%errorlevel%"
findstr /I /C:"ERROR" "%NAME%\xvlog.log" >NUL
set "ERR=%errorlevel%"
echo [%NAME%] defs='%DEFS%' xvlog_rc=%RC% implicit_hit=%IMP% error_hit=%ERR%
if not "%RC%"=="0" (
  set /a FAILS+=1
  echo   ---- %NAME% xvlog log tail ----
  powershell -NoProfile -Command "Get-Content -Tail 12 '%NAME%\xvlog.log'"
)
if "%IMP%"=="0" (
  set /a FAILS+=1
  echo   ---- %NAME% implicit-net hits ----
  findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" "%NAME%\xvlog.log"
)
if "%ERR%"=="0" (
  set /a FAILS+=1
  echo   ---- %NAME% ERROR hits ----
  findstr /I /C:"ERROR" "%NAME%\xvlog.log"
)
exit /b 0
