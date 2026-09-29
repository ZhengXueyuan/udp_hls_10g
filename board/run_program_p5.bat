@echo off
set "REPO_ROOT=%~dp0..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

REM run_program_p5.bat - JTAG 1MHz program the P5 app bitstream
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;%PATH%
cd /d %REPO_ROOT%
REM -log/-nojournal MUST precede -tclargs (Vivado -tclargs is greedy and swallows
REM the rest -> -log silently ignored, no log file, see run_program_p5_keep.bat).
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %REPO_ROOT%\board\program_p4.tcl -log vivado_program_p5.log -nojournal -tclargs %REPO_ROOT%/vivado_prj/p5_prj.runs/impl_1/wrapper_p4.bit
