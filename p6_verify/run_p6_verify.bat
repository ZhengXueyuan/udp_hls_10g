@echo off
set "REPO_ROOT=%~dp0..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

REM run_p6_verify.bat - read-only P6 gate-B verification (both routed checkpoints)
REM inputs: vivado_prj/p6_t8p0_prj.runs/impl_1/wrapper_p4_routed.dcp
REM         vivado_prj/p6_t6p4_prj.runs/impl_1/wrapper_p4_routed.dcp
REM outputs: p6_verify/p6_*.rpt + p6_*_failing_endpoints.txt
REM from Git Bash: cmd //c 'D:\repo\ECO\udp_hls_10g\p6_verify\run_p6_verify.bat'
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d %REPO_ROOT%
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %REPO_ROOT%\p6_verify\p6_verify.tcl -log vivado_p6_verify.log -nojournal
