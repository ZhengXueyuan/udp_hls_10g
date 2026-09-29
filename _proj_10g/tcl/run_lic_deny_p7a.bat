@echo off
REM ============================================================================
REM  run_lic_deny_p7a.bat -- P7a licence negative control
REM
REM  Flow: baseline md5 -> preguard -> RENAME Xilinx.lic away -> run Vivado
REM        probe -> RESTORE (unconditional) -> verify md5 identical.
REM  Modelled on _lic\run_deny.bat, which already did this once for
REM  xxv_ethernet; the restore step runs even if Vivado fails.
REM
REM  WARNING: DO NOT run this while another Vivado build is in flight: hiding the
REM    licence can break that build's own licence checkouts.
REM  WARNING: Never leave the machine with the licence renamed -- the state file must
REM    end with RESTORE_LIC_PRESENT=OK and the two md5 values identical.
REM
REM  From Git Bash: cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\tcl\run_lic_deny_p7a.bat'
REM ============================================================================
setlocal
set LICDIR=C:\AMDDesignTools\2025.2\data\ip\core_licenses
set LIC=%LICDIR%\Xilinx.lic
set HID=%LICDIR%\Xilinx.lic.HIDDEN
set WORK=%~dp0..
set VIV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
set ST=%WORK%\reports\p7a_lic_deny_state.txt

echo ==================== STEP0 BASELINE ==================== > "%ST%"
dir "%LIC%" >> "%ST%" 2>&1
certutil -hashfile "%LIC%" MD5 >> "%ST%" 2>&1

echo ==================== STEP1 PREGUARD =================== >> "%ST%"
if exist "%HID%" echo PREGUARD_HIDDEN_ALREADY_EXISTS_ABORT_RENAME=YES >> "%ST%"
if not exist "%HID%" echo PREGUARD_HIDDEN_ALREADY_EXISTS_ABORT_RENAME=NO >> "%ST%"

echo ==================== STEP2 RENAME AWAY ================ >> "%ST%"
if not exist "%HID%" ren "%LIC%" "Xilinx.lic.HIDDEN" >> "%ST%" 2>&1
if exist "%LIC%" echo RENAME_RESULT=LIC_STILL_PRESENT_FAIL >> "%ST%"
if exist "%HID%" echo RENAME_RESULT=HIDDEN_OK >> "%ST%"

echo ==================== STEP3 VIVADO LICENCE-ABSENT ====== >> "%ST%"
call "%VIV%" -mode batch -source "%~dp0lic_deny_p7a.tcl" -log "%WORK%\reports\p7a_lic_deny.log" -journal "%WORK%\reports\p7a_lic_deny.jou" > "%WORK%\reports\p7a_lic_deny_stdout.txt" 2>&1
echo VIVADO_EXITCODE=%ERRORLEVEL% >> "%ST%"

echo ==================== STEP4 RESTORE ==================== >> "%ST%"
if exist "%HID%" move /y "%HID%" "%LIC%" >> "%ST%" 2>&1
if exist "%LIC%" echo RESTORE_LIC_PRESENT=OK >> "%ST%"
if not exist "%LIC%" echo RESTORE_LIC_PRESENT=FAIL >> "%ST%"
if exist "%HID%" echo RESTORE_HIDDEN_STILL_THERE=FAIL >> "%ST%"
if not exist "%HID%" echo RESTORE_HIDDEN_STILL_THERE=NO_OK >> "%ST%"

echo ==================== STEP5 VERIFY ===================== >> "%ST%"
certutil -hashfile "%LIC%" MD5 >> "%ST%" 2>&1

echo ---- key readings ----
findstr /C:"SUBJ_" /C:"CTRL_" /C:"WARNING" /C:"RESTORE_" /C:"VIVADO_EXITCODE" "%WORK%\reports\p7a_lic_deny_stdout.txt" "%ST%"
exit /b 0
