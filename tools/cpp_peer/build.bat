@echo off
rem ===================================================================
rem build.bat -- build peer.exe with MinGW-w64 g++
rem
rem Toolchain probe results on this host (2026-09-19):
rem   compiler : C:\msys64\mingw64\bin\g++.exe   GCC 16.1.0 (MSYS2)
rem              (no C:\Qt, no cl.exe on PATH, no TDM/Cygwin)
rem   pcap SDK : NOT PRESENT (no C:\npcap-sdk, no pcap.h anywhere)
rem   pcap dll : C:\Windows\System32\wpcap.dll (WinPcap 4.1.3 API, npcap
rem              driver npcap.sys is the one actually running)
rem   => no headers/lib needed: peer.cpp declares the few WinPcap entry
rem      points itself and links straight against the DLL.
rem
rem GOTCHA: mingw64\bin MUST be on PATH. cc1.exe silently fails to start
rem (exit code 1, zero output) if its DLLs are not findable.
rem
rem Run from cmd:   build.bat
rem Run from bash:  cmd //c 'D:\repo\ECO\udp_hls_10g\tools\cpp_peer\build.bat'
rem ===================================================================

setlocal

set "MINGW=C:\msys64\mingw64\bin"
set "GXX=%MINGW%\g++.exe"
set "WPCAP=C:\Windows\System32\wpcap.dll"

if not exist "%GXX%" (
    echo [build] ERROR: g++ not found at %GXX%
    echo [build] Edit MINGW in this script to point at your MinGW bin dir.
    exit /b 1
)
if not exist "%WPCAP%" (
    echo [build] ERROR: wpcap.dll not found at %WPCAP%
    echo [build] Install npcap or WinPcap first.
    exit /b 1
)

set "PATH=%MINGW%;%PATH%"

echo [build] compiler: %GXX%
echo [build] pcap dll: %WPCAP%
echo [build] compiling peer.cpp ...

"%GXX%" -O2 -std=c++17 -static -Wall -Wextra -Wno-unused-parameter "%~dp0peer.cpp" -o "%~dp0peer.exe" -lws2_32 "%WPCAP%"
if errorlevel 1 (
    echo [build] FAILED
    exit /b 1
)

echo [build] OK
echo.
echo [build] capture devices visible to this binary:
"%~dp0peer.exe" --list

endlocal
exit /b 0
