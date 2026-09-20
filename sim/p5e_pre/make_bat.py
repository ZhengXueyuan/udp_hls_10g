#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Generate run_tb_p5_udp_split.bat in sim/p5e_pre (CRLF endings -- project rule).

ASCII-ONLY on purpose (memory: windows-bat-execution-gotchas -- UTF-8 CJK in a
.bat on this machine eats the CR and the comment gets executed as a command).
"""
import io
import os

D = os.path.dirname(os.path.abspath(__file__))

RTL_LIST = r"""  %RTL%\crc32_8b.v ^
  %RTL%\fifo_sync.v ^
  %RTL%\checksum16.v ^
  %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v ^
  %RTL%\mac_tx_64.v ^
  %RTL%\tcp_cam.v ^
  %RTL%\tcb.v ^
  %RTL%\tcp_rx.v ^
  %RTL%\tcp_tx_frame.v ^
  %RTL%\retx_ram.v ^
  %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v ^
  %RTL%\rx_classify.v ^
  %RTL%\vlan_strip.v ^
  %RTL%\slow_cfg_adp.v ^
  %RTL%\tx_arb.v ^
  %RTL%\udp_rx.v ^
  %RTL%\app_ctrl.v ^
  %RTL%\app_pattern.v ^
  %RTL%\app_status_uart.v ^
  %BD%\uart_dbg.v ^
"""

bat = r"""@echo off
REM run_tb_p5_udp_split.bat -- P5e pre-experiment A/B runner (ZERO RTL change)
REM
REM usage: run_tb_p5_udp_split.bat [base^|nostall^|stall^|harsh^|r2^|r2stall^|r3]
REM   base    : tb_p5_baseline.v = tb\tb_p5_app.v verbatim (module+resp name only)
REM   nostall : tb_p5_udp_split.v = baseline + (rx_classify slow port -> udp_rx),
REM             udp_rx m_axis_tready tied 1
REM   stall   : +UDPSTALL  -> tready 3 high 1 low  (light backpressure)
REM   harsh   : +UDPHARSH  -> 100 of every 2100 cycles ready (duty 0.048, far
REM             below the 0.125 1G word rate) => probes MAC 8-deep FIFO overflow
REM   r2      : P5E_ROUND=2 -> adds malformed-length / multicast frames
REM   r2stall : P5E_ROUND=2 + UDPSTALL
REM   r3      : P5E_ROUND=3 -> pcount 12-bit wrap probe (payload 4095/4096/5000)
REM
REM env P5SMALL=1 adds -d P5_SMALL (TB's own knob, TB_TX_BYTES=65536) to shorten
REM the run; default = full 1MB (comparable with the canonical P5a gate).
REM isolation: own xsim.dir here (project rule 7).  rtl\ is referenced READ-ONLY.
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set BD=D:\repo\ECO\udp_hls_10g\board
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5e_pre
set CASE=%1
if "%CASE%"=="" set CASE=nostall
set PLUS=
set SRCF=tb_p5_udp_split.v
set MODL=tb_p5_udp_split
set DEF=
if /I "%CASE%"=="stall"   set PLUS=-testplusarg UDPSTALL
if /I "%CASE%"=="harsh"   set PLUS=-testplusarg UDPHARSH
if /I "%CASE%"=="r2stall" set PLUS=-testplusarg UDPSTALL
if /I "%CASE%"=="r2"      set P5E_ROUND=2
if /I "%CASE%"=="r2stall" set P5E_ROUND=2
if /I "%CASE%"=="r3"      set P5E_ROUND=3
if /I "%CASE%"=="base"   set SRCF=tb_p5_baseline.v
if /I "%CASE%"=="base"   set MODL=tb_p5_baseline
if "%P5SMALL%"=="1" set DEF=-d P5_SMALL

%PY% %SIM%\gen_stim_p5e_udp.py %SIM% || exit /b 1

if exist xsim.dir rmdir /s /q xsim.dir

call %XV%\xvlog.bat -work xil_defaultlib %DEF% ^
""" + RTL_LIST + r"""  %SIM%\%SRCF% > xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_%CASE%.log 2>&1 || (type xvlog_%CASE%.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.%MODL% xil_defaultlib.glbl -s %MODL%_%CASE% -log xelab_%CASE%.log > NUL 2>&1 || (type xelab_%CASE%.log & exit /b 1)
call %XV%\xsim.bat %MODL%_%CASE% -runall %PLUS% -log xsim_%CASE%.log > NUL 2>&1 || (type xsim_%CASE%.log & exit /b 1)

if /I "%CASE%"=="base" goto done
copy /y resp_p5_udp_split.memh resp_p5_udp_split_%CASE%.memh > NUL
%PY% %SIM%\gen_stim_p5e_udp.py %SIM% check
exit /b %ERRORLEVEL%

:done
echo BASE run complete: resp_p5_baseline.memh
exit /b 0
"""

p = os.path.join(D, 'run_tb_p5_udp_split.bat')
with io.open(p, 'w', newline='\r\n', encoding='ascii') as fh:
    fh.write(bat)
print('written %s (%d ascii bytes, CRLF)' % (p, len(bat)))
