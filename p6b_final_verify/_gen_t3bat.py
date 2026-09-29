#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate p6b_final_verify/run_t3_f2.bat (ASCII + CRLF).

Lifted from audit_scratch/run_t3.bat (copied, not modified). Only the work-dir roots
are redirected into p6b_final_verify/t3_f2 so nothing outside this dir is touched.
"""
import os

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
DST = os.path.join(ROOT, "p6b_final_verify", "run_t3_f2.bat")
XV = r"C:\AMDDesignTools\2025.2\Vivado\bin"

L = [
    "@echo off",
    "REM run_t3_f2.bat -- F-2 (mac_tx_64 mid-frame abort residue) verdict gate, re-run on the",
    "REM   FROZEN tree. Lifted from audit_scratch/run_t3.bat (copied, not modified); all work",
    "REM   dirs live under p6b_final_verify/t3_f2 so nothing outside this dir is touched.",
    "REM usage: run_t3_f2.bat [pos^|orig^|nostall_new^|nostall_orig]   (default pos)",
    "REM   pos / nostall_new   : NEW rtl/mac_tx_64.v  -^> expect PASS (ghost=0)",
    "REM   orig / nostall_orig : OLD mac_tx_64_orig.v -^> negative control, MUST FAIL (ghost=1)",
    "REM   nostall_* pair      : FPRINT of the wire stream must MATCH (proves no-regression)",
    "setlocal",
    "set XV=" + XV,
    "set ROOT=" + ROOT,
    r"set P=%ROOT%\p6b_final_verify\t3_f2",
    "set CASE=%1",
    'if "%CASE%"=="" set CASE=pos',
    r"set RTL=%ROOT%\rtl\mac_tx_64.v",
    "set DEFS=-d F2_RTL",
    "set PA=",
    'if /i "%CASE%"=="orig"         set RTL=%P%\\mac_tx_64_orig.v',
    'if /i "%CASE%"=="orig"         set DEFS=',
    'if /i "%CASE%"=="nostall_new"  set PA=-testplusarg NOSTALL',
    'if /i "%CASE%"=="nostall_orig" set RTL=%P%\\mac_tx_64_orig.v',
    'if /i "%CASE%"=="nostall_orig" set DEFS=',
    'if /i "%CASE%"=="nostall_orig" set PA=-testplusarg NOSTALL',
    r"set CDIR=%P%\case_%CASE%",
    'if not exist "%CDIR%" mkdir "%CDIR%"',
    'cd /d "%CDIR%"',
    "if exist xsim.dir rmdir /s /q xsim.dir",
    "call %XV%\\xvlog.bat -work xil_defaultlib %DEFS% "
    "%ROOT%\\rtl\\crc32_8b.v %ROOT%\\rtl\\fifo_sync.v %ROOT%\\rtl\\fifo_async.v "
    "%RTL% %P%\\tb_tx_cdc_chain.v > xvlog_run.log 2>&1 || (type xvlog_run.log & exit /b 1)",
    'findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xvlog_run.log >NUL && (echo IMPLICIT-DECL-FAIL & exit /b 1)',
    'findstr /C:"10-3091" xvlog_run.log >NUL && (echo BITWIDTH-MISMATCH-FAIL & exit /b 1)',
    "call %XV%\\xelab.bat -debug typical -timescale 1ns/1ps -L xil_defaultlib "
    "xil_defaultlib.tb_tx_cdc_chain -s tb_tx_cdc_chain -log xelab_run.log > NUL 2>&1 "
    "|| (type xelab_run.log & exit /b 1)",
    # an implicit net used as a PORT CONNECTION is invisible to xvlog; xelab is the
    # only place it shows up (VRFC 10-3091).  Added 2026-09-29 with the keyword fix.
    'findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" xelab_run.log >NUL && (echo IMPLICIT-DECL-FAIL-XELAB & exit /b 1)',
    "call %XV%\\xsim.bat tb_tx_cdc_chain -runall %PA% -log xsim_%CASE%.log > NUL 2>&1",
    'findstr /C:"TXCHAIN" /C:"WIRE" /C:"FPRINT" xsim_%CASE%.log',
    'findstr /C:"TXCHAIN: PASS_ALL" xsim_%CASE%.log >NUL',
    "if errorlevel 1 (echo T3[%CASE%] FAIL & exit /b 1)",
    "echo T3[%CASE%] PASS",
    "exit /b 0",
]

data = ("\r\n".join(L) + "\r\n").encode("ascii")
with open(DST, "wb") as f:
    f.write(data)
print("written %s  (%d bytes)" % (DST, len(data)))
