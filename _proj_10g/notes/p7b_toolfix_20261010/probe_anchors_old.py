#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_anchors_old.py — READ-ONLY 锚点命中表 (修复前的旧逻辑复刻).

用途: 给出两支变异生成脚本的"修前"逐锚点命中表 (证据件), **一个字节都不写**。
做法: 用 ast 从脚本源码里抽出 add(...) 的字面实参 (不 import ⇒ 不触发落盘),
      再按**该脚本自己的读侧口径**读 RTL 并计数。

usage: python probe_anchors_old.py <mutgen.py> [--newline-none|--newline-raw] <rtl file>
  --newline-none : 复刻 io.open(..., newline=None)  —— 通用换行, CRLF 在**读侧**即被归一成 LF
  --newline-raw  : 复刻 io.open(..., newline="")  —— 原样保留 CRLF (裸 \n 多行锚点会 MISS)
"""
import ast
import io
import sys


def literal_adds(path):
    """返回 [(name, [(old, new, expect)], note)] —— 只取字面量实参."""
    tree = ast.parse(io.open(path, encoding="utf-8").read(), path)
    out = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        fn = node.func
        if not (isinstance(fn, ast.Name) and fn.id == "add"):
            continue
        vals = []
        for a in node.args:
            try:
                vals.append(ast.literal_eval(a))
            except Exception as e:
                vals.append("<non-literal: %s>" % e)
        if len(vals) == 3 and isinstance(vals[1], list):
            out.append((vals[0], vals[1], vals[2]))
    return out


def main(argv):
    gen = argv[0]
    mode = argv[1]
    rtl = argv[2]
    raw = open(rtl, "rb").read()
    n_crlf = raw.count(b"\r\n")
    if mode == "--newline-none":
        src = io.open(rtl, encoding="utf-8").read()          # 通用换行 (归一)
    elif mode == "--newline-raw":
        src = io.open(rtl, encoding="utf-8", newline="").read()   # 原样 (CRLF 保留)
    else:
        raise SystemExit("bad mode %s" % mode)
    print("GEN   %s" % gen)
    print("MODE  %s    RTL %s  %d B  %d CRLF" % (mode, rtl, len(raw), n_crlf))
    bad = 0
    for name, subs, note in literal_adds(gen):
        for i, sub in enumerate(subs, 1):
            old, new, exp = sub
            n = src.count(old)
            ok = (n == exp)
            if not ok:
                bad += 1
            print("%-14s s%-2d hits=%d expect=%d %s" % (name, i, n, exp,
                                                        "" if ok else "<== MISMATCH"))
    print("TOTAL_MISMATCH=%d" % bad)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
