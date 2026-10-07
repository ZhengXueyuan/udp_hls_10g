#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_default_equiv.py -- 独立复核 "默认构建零回归" (不借作者的 apply_rx8.py).

做法: 自己写一个**极简 Verilog 预处理器** (只认 `ifdef / `ifndef / `else / `elsif /
`endif, 未定义集合 = {}), 把工作副本 rtl/app_pattern.v 按"宏全关"展开, 与
`git show HEAD:rtl/app_pattern.v` **逐字节**比对.

同时把"P7B_10G 开、其它关"展开一遍, 报行数 (作者声称 743 行) 与新增行数。
任何与预期不符 ⇒ 退出码 1 (不静默).
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "app_pattern.v")


def preprocess(text, defined):
    out = []
    # 栈元素: (parent_active, this_branch_active, seen_else)
    stack = []
    active = True
    for lineno, line in enumerate(text.splitlines(True), 1):
        s = line.lstrip()
        if s.startswith("`ifdef") or s.startswith("`ifndef"):
            neg = s.startswith("`ifndef")
            name = s.split()[1].strip()
            cond = (name in defined)
            if neg:
                cond = not cond
            stack.append((active, active and cond, False))
            active = active and cond
            continue
        if s.startswith("`else"):
            if not stack:
                raise RuntimeError("`else without `ifdef at line %d" % lineno)
            pa, _, seen = stack[-1]
            if seen:
                raise RuntimeError("double `else at line %d" % lineno)
            stack[-1] = (pa, pa and not stack[-1][1], True)
            active = stack[-1][1]
            continue
        if s.startswith("`endif"):
            if not stack:
                raise RuntimeError("`endif without `ifdef at line %d" % lineno)
            pa, _, _ = stack.pop()
            active = pa
            continue
        if s.startswith("`elsif"):
            raise RuntimeError("`elsif not handled (line %d) -- extend me" % lineno)
        if active:
            out.append(line)
    if stack:
        raise RuntimeError("unterminated `ifdef")
    return "".join(out)


def main():
    cur = io.open(SRC, encoding="utf-8", newline="").read()
    head = subprocess.run(["git", "-C", ROOT, "show", "HEAD:rtl/app_pattern.v"],
                          capture_output=True).stdout.decode("utf-8")
    # 语义判据: 两个文件在"宏全关"下的**展开结果**必须逐字节相同。
    # (直接拿展开结果比 HEAD 原文是错的 —— HEAD 是带指令的原文。)
    dflt_cur = preprocess(cur, set())
    dflt_head = preprocess(head, set())
    p7b = preprocess(cur, {"P7B_10G"})
    p7b_head = preprocess(head, {"P7B_10G"})

    same = (dflt_cur == dflt_head)
    print("default expand: current %d bytes vs HEAD %d bytes: %s"
          % (len(dflt_cur.encode()), len(dflt_head.encode()),
             "IDENTICAL" if same else "DIFFER"))
    if not same:
        import difflib
        a = dflt_head.splitlines()
        b = dflt_cur.splitlines()
        for ln in list(difflib.unified_diff(a, b, "HEAD-expand", "cur-expand", lineterm=""))[:40]:
            print("  " + ln)
        return 1
    print("P7B_10G expand: current %d lines, HEAD %d lines (delta = %d = the added RX8 block)"
          % (p7b.count("\n"), p7b_head.count("\n"), p7b.count("\n") - p7b_head.count("\n")))
    print("default expand lines: cur %d / HEAD %d" % (dflt_cur.count("\n"), dflt_head.count("\n")))
    print("DEFAULT-EQUIV: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
