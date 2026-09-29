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
REM run_program_echo.bat — ECO 板 JTAG 1MHz 烧录 wrapper_echo.bit
REM 从 Git Bash 调用: cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_echo.bat'
REM 成功判据: 日志末尾 "PROGRAM_OK" (program_hw_devices 打印
REM           "End of startup status: HIGH" = DONE=HIGH)
REM 参照: udp_hls_eco\_run_prog_caller.bat (全路径调用, cd /d 开头)
REM =============================================================================
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d %REPO_ROOT%
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source %REPO_ROOT%\board\program_echo.tcl -tclargs %REPO_ROOT%/vivado_prj/udp_echo_prj.runs/impl_1/wrapper_echo.bit -log vivado_prog_echo.log -nojournal
