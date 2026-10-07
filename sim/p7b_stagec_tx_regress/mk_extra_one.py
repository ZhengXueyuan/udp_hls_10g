# -*- coding: utf-8 -*-
"""后补一条门 (p5_wrapper) 的两个臂副本 —— 与 mk_extra.py 同规则, 但**只写它自己**,
不动已在跑的其他门目录 (mk_extra.py 会 rmtree 整棵树)。
用法: python mk_extra_one.py p5_wrapper
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HEAD = os.path.join(HERE, "head_rtl")

GATE = sys.argv[1] if len(sys.argv) > 1 else "p5_wrapper"
SRC = os.path.join(ROOT, "sim", "p5sim", "run_tb_%s.bat" % GATE)

for arm in ("extra", "extra_head"):
    dst = os.path.join(HERE, arm)
    os.makedirs(dst, exist_ok=True)
    d = os.path.join(dst, GATE)
    os.makedirs(d, exist_ok=True)
    b = open(SRC, "rb").read()
    assert b.count(b"\r\n") == b.count(b"\n")
    for a, r in ((r'set "REPO_ROOT=%~dp0..\..\."',
                  r'set "REPO_ROOT=%~dp0..\..\..\..\.'),
                 (r"set SIM=%REPO_ROOT%\sim\p5sim", r"set SIM=%~dp0")):
        assert b.count(a.encode()) == 1, (a, b.count(a.encode()))
        b = b.replace(a.encode(), r.encode())
    if arm == "extra_head":
        a = r"set RTL=%REPO_ROOT%\rtl"
        assert b.count(a.encode()) == 1
        b = b.replace(a.encode(), ("set RTL=" + HEAD).encode())
    assert b.count(b"\r\n") == b.count(b"\n")
    open(os.path.join(d, "run.bat"), "wb").write(b)
    print("%s/%s written (%d bytes, CRLF preserved)" % (arm, GATE, len(b)))
