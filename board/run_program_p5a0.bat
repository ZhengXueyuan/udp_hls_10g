@echo off
set "REPO_ROOT=%~dp0..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

REM run_program_p5a0.bat - JTAG 1MHz program the P5a-0 experiment bitstream
REM (APP_MODE=1 => per-segment pure ACK); p4_prj bitstream is untouched
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d %REPO_ROOT%
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %REPO_ROOT%\board\program_p4.tcl -tclargs %REPO_ROOT%/vivado_prj/p5a0_prj.runs/impl_1/wrapper_p4.bit -log vivado_program_p5a0.log -nojournal
