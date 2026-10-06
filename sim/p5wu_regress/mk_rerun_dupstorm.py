#!/usr/bin/env python
"""Generate rerun_dupstorm.bat (ASCII + CRLF) in MY scratch dir.

Replays the EXACT matrix invocation of the dupstorm gate
(run_tb_p4_burst.bat <args = "200 0 0 4000 608 dup">) in a private work dir
of mine, so the shared sim/p4sim/matrix_p4dfix.log and the matrix work tree
are untouched.  Used to answer: was the 2026-10-07 02:00 xsim engine crash
("Simulation engine not responding") reproducible, or a one-off?
"""
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

bat = [
    "@echo off",
    'set "REPO_ROOT=%~dp0..\\..\\."',
    'for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"',
    'set "P4_WORKDIR=%~dp0dupstorm_rerun"',
    'if not exist "%P4_WORKDIR%" mkdir "%P4_WORKDIR%"',
    'call "%REPO_ROOT%\\sim\\p4sim\\run_tb_p4_burst.bat" 200 0 0 4000 608 dup',
    'set "RC=%ERRORLEVEL%"',
    "echo RERUN_DUPSTORM_EXIT=%RC%",
    "exit /b %RC%",
]
open("sim/p5wu_regress/rerun_dupstorm.bat", "wb").write(
    ("\r\n".join(bat) + "\r\n").encode("ascii"))
print("wrote sim/p5wu_regress/rerun_dupstorm.bat")
