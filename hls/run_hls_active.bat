@echo off
set "REPO_ROOT=%~dp0..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

REM udp_hls_10g\hls\run_hls_active.bat -- P5 PCACTIVE sim netlist (ACTIVE_CONNECT=1)
REM Products: hls\slowstack_prj\solution1\syn\verilog\ (sim reads this dir).
REM WARNING: overwrites the default (ACTIVE_CONNECT=0) netlist -- re-run
REM          run_hls.bat afterwards for the chain/burst regression gates.
REM From Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\hls\run_hls_active.bat'
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d %REPO_ROOT%\hls
C:\AMDDesignTools\2025.2\Vitis\bin\vitis-run.bat --mode hls --tcl --part xc7k325tffg676-2 --freqhz 125000000 run_hls_active.tcl
