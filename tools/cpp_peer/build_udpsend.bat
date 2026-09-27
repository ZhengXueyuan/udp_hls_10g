@echo off
rem ===================================================================
rem build_udpsend.bat -- build udpsend.exe with MinGW-w64 g++
rem
rem GOTCHA (same as build.bat): mingw64\bin MUST be on PATH, otherwise
rem cc1.exe silently fails to start (exit code 1, zero output).
rem ===================================================================
set PATH=C:\msys64\mingw64\bin;%PATH%
cd /d D:\repo\ECO\udp_hls_10g\tools\cpp_peer
call g++.exe -O2 -std=c++17 -o udpsend.exe udpsend.cpp -lws2_32
if errorlevel 1 (echo BUILD_FAILED & exit /b 1)
findstr /C:"BUILD" NUL >NUL 2>NUL
echo BUILD_OK
exit /b 0
