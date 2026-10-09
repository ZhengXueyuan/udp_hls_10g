@echo off
REM read-only JTAG probe (ASCII + CRLF); NO program_hw_devices; NEVER writes QSPI
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %~dp0jtag_probe_readonly.tcl -nojournal -nolog > %~dp0jtag_probe_stdout.txt 2>&1
echo JTAG_PROBE_EXIT=%ERRORLEVEL%
