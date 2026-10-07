#!/usr/bin/env python
"""mk_head_ab.py -- build the HEAD-version A/B arms of a gate .bat.

For every gate that turns red I must decide 既存红 (pre-existing at HEAD) vs
新红 (introduced by the P1/P2 + window change).  The A/B arm is the SAME gate
.bat with exactly one (or two) token(s) repointed at the HEAD copy of the two
changed files, exported by:
    git show 95c9485:rtl/app_ctrl.v     -> sim/p5wu_p1p2_regress/head_rtl/app_ctrl.v
    git show 95c9485:board/wrapper_p4.v -> sim/p5wu_p1p2_regress/head_rtl/wrapper_p4.v
Everything else is byte-identical.

usage: python mk_head_ab.py <src_bat(repo-rel)> <arms> <wd_suffix>
       arms = csv subset of {ctrl,wrap}   e.g.  ctrl,wrap   |  ctrl   |  (none)
       wd_suffix = work dir suffix, e.g. head
"""
import hashlib
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

OUT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(OUT, "..", ".."))
os.chdir(REPO)

src = sys.argv[1]
arms = [a for a in sys.argv[2].split(",") if a]
suf = sys.argv[3]

SUB = {
    "ctrl": (b"%RTL%\\app_ctrl.v", b"%~dp0head_rtl\\app_ctrl.v"),
    "wrap": (b"%BD%\\wrapper_p4.v", b"%~dp0head_rtl\\wrapper_p4.v"),
}
OLD_CD = b"cd /d %~dp0\r\n"

raw = io.open(src, "rb").read()
name = os.path.basename(src)[:-4]
wd = "work_%s_%s" % (name, suf)
t = raw
assert t.count(OLD_CD) == 1, "cd token count = %d" % t.count(OLD_CD)
for a in arms:
    old, new = SUB[a]
    c = t.count(old)
    assert c == 1, "token %s appears %d times in %s" % (old, c, src)
    t = t.replace(old, new)
    print("  sub %-4s %s -> %s" % (a, old.decode(), new.decode()))
ins = (b"cd /d %~dp0\r\n"
       b"if not exist \"%~dp0" + wd.encode() + b"\" mkdir \"%~dp0" + wd.encode() + b"\"\r\n"
       b"cd /d \"%~dp0" + wd.encode() + b"\"\r\n")
t = t.replace(OLD_CD, ins)
SIMTOK = b"set SIM=%REPO_ROOT%\\sim\\p5sim"
if SIMTOK in t:
    t = t.replace(SIMTOK, b"set SIM=%~dp0" + wd.encode())
t = t.replace(b"set SIM=%~dp0\r\n", b"set SIM=%~dp0" + wd.encode() + b"\r\n")
out = os.path.join(OUT, "%s_%s.bat" % (name, suf))
io.open(out, "wb").write(t)
print("src  %s sha256=%s" % (src, hashlib.sha256(raw).hexdigest()[:16]))
print("wrote %s (%d bytes, work dir %s)" % (out, len(t), wd))
