# -*- coding: utf-8 -*-
"""Generate board/run_build_p7b_ku5p.bat (ASCII + CRLF, project rule)."""
import io

BODY = r'''@echo off
REM run_build_p7b_ku5p.bat - P7b 10G front end (official xxv_ethernet PCS + our own
REM   64-bit XGMII MAC) merged with the 64-bit datapath.  THIS SCRIPT DOES NOT
REM   PROGRAM THE BOARD (no program_hw_devices, no QSPI).
REM   from Git Bash: cmd //c 'board\run_build_p7b_ku5p.bat'
setlocal
cd /d %~dp0
set VV=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat
if not exist p7b_ku5p_stdout.txt del /q p7b_ku5p_stdout.txt
call "%VV%" -mode batch -source "%~dp0build_p7b_ku5p.tcl" -nojournal -nolog > p7b_ku5p_stdout.txt 2>&1
echo BUILD_EXIT=%ERRORLEVEL%

REM ---- hard gates (a hit is a FAILURE, not a note) --------------------------
findstr /I /C:"12-4739" p7b_ku5p_stdout.txt >NUL && (echo DROPPED-CONSTRAINT-FAIL & findstr /I /C:"12-4739" p7b_ku5p_stdout.txt)
findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" p7b_ku5p_stdout.txt >NUL && (echo IMPLICIT-NET-FAIL & findstr /I /C:"Synth 8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091] actual bit length 1 differs from formal bit length" /C:"VRFC 10-2989" /C:"implicitly declared" p7b_ku5p_stdout.txt)
findstr /I /C:"NSTD-1" /C:"UCIO-1" /C:"AVAL-326" /C:"Opt 31-155" /C:"Opt 31-67" /C:"Route 35-7" p7b_ku5p_stdout.txt >NUL && (echo DRC-KEY-FAIL & findstr /I /C:"NSTD-1" /C:"UCIO-1" /C:"AVAL-326" /C:"Opt 31-155" /C:"Opt 31-67" /C:"Route 35-7" p7b_ku5p_stdout.txt)

REM ---- readings (must be present in the log, not merely in a report file) ---
findstr /B /C:"P7B_WNS" /C:"P7B_WHS" /C:"P7B_WPWS" /C:"P7B_BIT_EXISTS" /C:"P7B_VERDICT" /C:"P7B_CONVERGED_AT_ROUND" /C:"P7B_IS_LOCKED_POSTGEN" /C:"P7B DONE" p7b_ku5p_stdout.txt

if not exist "..\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4.bit" (echo NO-BITSTREAM & exit /b 1)
echo BITSTREAM-OK
exit /b 0
'''

s = BODY.replace('\n', '\r\n')
assert all(ord(c) < 128 for c in s), 'non-ASCII in bat'
io.open('D:/repo/XCKU5PMini/udp_hls_10g/board/run_build_p7b_ku5p.bat', 'wb').write(s.encode('ascii'))
print('wrote run_build_p7b_ku5p.bat')
