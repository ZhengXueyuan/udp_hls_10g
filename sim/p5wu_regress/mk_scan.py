#!/usr/bin/env python
"""Generate scan_logs.bat (ASCII + CRLF) in MY scratch dir.

Runs the canonical trap-24 detector (sim/p4gates/implicit_gate.bat) over
every compile log produced by MY runs: the p5/p5d/p5wu gate logs and the whole
work tree of MY matrix run (sim/p4gates/work_20261007_014439).  Each .log
under the matrix work tree is scanned (the "runme.log family" of the sim
gates); the gate console logs (_gate_console.log) are scanned too.
"""
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

LOGS = [
    r"sim\p5wu\run\xvlog_wu.log", r"sim\p5wu\run\xelab_wu.log",
    r"sim\p5sim\fcrun\xvlog_fc.log", r"sim\p5sim\fcrun\xelab_fc.log",
    r"sim\p5sim\flowrun\xvlog_flow.log", r"sim\p5sim\flowrun\xelab_flow.log",
    r"sim\p5sim\xvlog_tb.log", r"sim\p5sim\xelab_run.log",
    r"sim\p5sim\xvlog_st.log", r"sim\p5sim\xelab_st.log",
    r"sim\p5sim\xvlog_p.log", r"sim\p5sim\xelab_p.log",
    r"sim\p5sim\xvlog_w.log", r"sim\p5sim\xvlog_w_hls.log", r"sim\p5sim\xelab_w.log",
    r"sim\p5sim\xvlog_adv.log", r"sim\p5sim\xelab_adv.log",
    r"sim\p5d_multi\main\xvlog_multi.log", r"sim\p5d_multi\main\xelab_multi.log",
    r"sim\p5wu_regress\wraphead\xvlog_w.log", r"sim\p5wu_regress\wraphead\xelab_w.log",
    r"sim\p5wu_regress\wraphead\xvlog_w_hls.log",
    r"sim\p5wu_regress\wrapnew\xvlog_w.log", r"sim\p5wu_regress\wrapnew\xelab_w.log",
    r"sim\p5wu_regress\wrapnew\xvlog_w_hls.log",
]

lines = ["@echo off", "setlocal", 'set "REPO_ROOT=%~dp0..\\..\\."',
         'for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"',
         'cd /d "%REPO_ROOT%"']
for L in LOGS:
    lines.append('call sim\\p4gates\\implicit_gate.bat "%s" "[static]"' % L)
lines.append('for /r "%REPO_ROOT%\\sim\\p4gates\\work_20261007_014439" %%F in (*.log) do call sim\\p4gates\\implicit_gate.bat "%%F" "[matrix]"')
lines.append("exit /b 0")
bat = "\r\n".join(lines) + "\r\n"
open("sim/p5wu_regress/scan_logs.bat", "wb").write(bat.encode("ascii"))
print("wrote sim/p5wu_regress/scan_logs.bat (%d lines)" % len(lines))
