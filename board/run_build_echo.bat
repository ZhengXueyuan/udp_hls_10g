@echo off
set "REPO_ROOT=%~dp0..\."
for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
if not exist "%REPO_ROOT%\CLAUDE.md" (
  echo [PATHGUARD FAIL] cannot locate this checkout from %~f0
  echo   derived REPO_ROOT = %REPO_ROOT%
  exit /b 1
)

REM =============================================================================
REM run_build_echo.bat — Vivado 2025.2 批处理构建 UDP echo 工程 (synth + impl + bitstream)
REM 产物: D:\repo\ECO\udp_hls_10g\vivado_prj\udp_echo_prj.runs\impl_1\wrapper_echo.bit
REM 从 Git Bash 调用: cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_echo.bat'
REM 参照: udp_hls_eco\run_vivado_phy1g2.bat (全路径调用, cd /d 开头)
REM =============================================================================
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d %REPO_ROOT%
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %REPO_ROOT%\board\build_echo.tcl -log vivado_build_echo.log -nojournal
