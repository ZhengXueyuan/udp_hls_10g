#!/usr/bin/env python
"""Build patched copies of the three sim/p5sim gates INTO MY scratch dir
(sim/p5wu_p1p2_regress/), so the canonical sim/p5sim work dir is not touched
by this regression agent.

Only two token substitutions per file (asserted by count):
  * "cd /d %~dp0"  ->  cd into my per-gate work dir (mkdir if needed)
  * "set SIM=%REPO_ROOT%\\sim\\p5sim"  ->  set SIM=%~dp0<wd>
Everything else (DUT file list, checker invocation, exit codes) is byte-identical
to the canonical gate, so the gate semantics are unchanged.

The bats land at sim\\p5wu_p1p2_regress\\<name>.bat -- exactly two levels below
the repo root, which is what their own "set REPO_ROOT=%~dp0..\\..\\." line needs.
"""
import hashlib
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

OUT = os.path.dirname(os.path.abspath(__file__))          # = sim/p5wu_p1p2_regress
REPO = os.path.abspath(os.path.join(OUT, "..", ".."))
os.chdir(REPO)
print("repo root = %s" % REPO)
print("out dir   = %s" % OUT)

GATES = [
    ("sim/p5sim/run_tb_p5_wrapper.bat", "run_tb_p5_wrapper_here.bat", "work_wrapper"),
    ("sim/p5sim/run_tb_p5_status.bat",  "run_tb_p5_status_here.bat",  "work_status"),
    ("sim/p5sim/run_tb_p5_pattern.bat", "run_tb_p5_pattern_here.bat", "work_pattern"),
]
OLD_CD = b"cd /d %~dp0\r\n"
OLD_SIM = b"set SIM=%REPO_ROOT%\\sim\\p5sim"

for src, dst, wd in GATES:
    raw = open(src, "rb").read()
    print("%s  sha256=%s  bytes=%d" % (src, hashlib.sha256(raw).hexdigest()[:16], len(raw)))
    assert raw.count(OLD_CD) == 1, "cd token count = %d in %s" % (raw.count(OLD_CD), src)
    assert raw.count(OLD_SIM) == 1, "SIM token count = %d in %s" % (raw.count(OLD_SIM), src)
    ins = (b"cd /d %~dp0\r\n"
           b"if not exist \"%~dp0" + wd.encode() + b"\" mkdir \"%~dp0" + wd.encode() + b"\"\r\n"
           b"cd /d \"%~dp0" + wd.encode() + b"\"\r\n")
    t = raw.replace(OLD_CD, ins)
    t = t.replace(OLD_SIM, b"set SIM=%~dp0" + wd.encode())
    assert t.count(b"\r\n") == raw.count(b"\r\n") + 2
    out = os.path.join(OUT, dst)
    open(out, "wb").write(t)
    print("  -> %s  (%d bytes, work dir %s)" % (out, len(t), wd))
