#!/usr/bin/env python
"""Build two patched copies of sim/p5sim/run_tb_p5_wrapper.bat in MY scratch dir:
   run_wrap_head.bat  -- compiles the PRE-FIX rtl/app_ctrl.v (ff78247:rtl/app_ctrl.v)
   run_wrap_new.bat   -- compiles the CURRENT rtl/app_ctrl.v (post-fix)
Both write into their own work dir (wraphead / wrapnew) so the canonical
sim/p5sim dir and gate logs are not touched.  Read-only wrt the repo sources.
"""
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SRC = "sim/p5sim/run_tb_p5_wrapper.bat"
REPO = "sim/p5wu_regress"
src = open(SRC, "rb").read()

OLD_CTRL = b"%RTL%\\app_ctrl.v"
OLD_SIM = b"set SIM=%REPO_ROOT%\\sim\\p5sim"
OLD_CD = b"cd /d %~dp0\r\n"
assert src.count(OLD_CTRL) == 1, "app_ctrl token count = %d" % src.count(OLD_CTRL)
assert src.count(OLD_SIM) == 1, "SIM token count = %d" % src.count(OLD_SIM)
assert src.count(OLD_CD) == 1, "cd token count = %d" % src.count(OLD_CD)

arms = [
    ("head", b"%REPO_ROOT%\\" + REPO.encode() + b"\\head_rtl\\app_ctrl.v", "wraphead"),
    ("new", None, "wrapnew"),
]
for arm, ctrl, wd in arms:
    t = src
    if ctrl is not None:
        t = t.replace(OLD_CTRL, ctrl)
    t = t.replace(OLD_SIM, ("set SIM=%%~dp0%s" % wd).encode())
    ins = ("cd /d %%~dp0\r\n"
           "if not exist \"%%~dp0%s\" mkdir \"%%~dp0%s\"\r\n"
           "cd /d \"%%~dp0%s\"\r\n" % (wd, wd, wd)).encode()
    t = t.replace(OLD_CD, ins)
    out = "%s/run_wrap_%s.bat" % (REPO, arm)
    open(out, "wb").write(t)
    print("wrote %s (%d bytes, %d CRLF)" % (out, len(t), t.count(b"\r\n")))
