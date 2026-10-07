#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""核: 插进 rtl/tcp_tx_frame.v 的 799 行 == sim/p7b_stagec_tx/ovl_branch.v (逐字节).
   若不等, 则 apply_ovl.py 的 P1/P2/P3 证明的不是**盘上这份文件**。"""
import io, os, sys, hashlib
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
new  = io.open(os.path.join(ROOT, "rtl", "tcp_tx_frame.v"), encoding="utf-8", newline="").read()
base = io.open(os.path.join(ROOT, "sim", "p7b_stagec_tx", "tcp_tx_frame.v.base"), encoding="utf-8", newline="").read()
br   = io.open(os.path.join(ROOT, "sim", "p7b_stagec_tx", "ovl_branch.v"), encoding="utf-8", newline="").read()

# 重建法: 在基线的 ANCH2 之后插入 ovl_branch.v, 再在 ANCH_END 前插 `endif
ANCH2 = "    assign dbg_plen     = plen;\n"
ANCH_END = "\nendmodule"
assert base.count(ANCH2) == 1 and base.count(ANCH_END) == 1
rebuilt = base.replace(ANCH2, ANCH2 + br, 1)
assert rebuilt.count(ANCH_END) >= 1
rebuilt = rebuilt.replace(ANCH_END, "\n`endif" + ANCH_END, 1)
print("rebuilt == 盘上 rtl/tcp_tx_frame.v :", rebuilt == new)
print("新文件 sha256  =", hashlib.sha256(new.encode("utf-8")).hexdigest())
print("重建件 sha256  =", hashlib.sha256(rebuilt.encode("utf-8")).hexdigest())
if rebuilt != new:
    a, b = rebuilt.split("\n"), new.split("\n")
    for k in range(max(len(a), len(b))):
        x = a[k] if k < len(a) else "<EOF>"
        y = b[k] if k < len(b) else "<EOF>"
        if x != y:
            print("首个差异 @行 %d:\n  rebuilt: %r\n  盘上  : %r" % (k+1, x, y)); break
