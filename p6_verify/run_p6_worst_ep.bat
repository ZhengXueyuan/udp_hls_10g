@echo off
set "REPO_ROOT=%~dp0..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

REM run_p6_worst_ep.bat - read-only per-endpoint worst-400 + fanout census (both checkpoints)
REM outputs: p6_verify/p6_*_setup_ep400.rpt, p6_*_hold_ep400.rpt, p6_*_fanout.txt
REM from Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\p6_verify\run_p6_worst_ep.bat'
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d %REPO_ROOT%
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %REPO_ROOT%\p6_verify\p6_worst_ep.tcl -log vivado_p6_worst_ep.log -nojournal
