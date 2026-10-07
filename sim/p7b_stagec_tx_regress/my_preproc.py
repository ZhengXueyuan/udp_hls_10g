# -*- coding: utf-8 -*-
"""Stage C 回归: **我自己写的**极简 Verilog 预处理器 (不引用作者的工具)。

目的: 独立核"宏关构建 = 逐字回到 HEAD"这件事 —— 只看 `` `ifdef/`ifndef/`else/`endif``
(含嵌套), 其余行原样保留。三个结论:
  A. pp(工作区 tcp_tx_frame.v, 无宏)  == pp(HEAD tcp_tx_frame.v, 无宏)   逐字节
  B. pp(工作区 tcp_tx_frame.v, TCP_TX_OVL) != 上面 (差 = +799 行 / 0 删除)
  C. app_pattern.v 同款 (宏 = P7B_10G, 差 = +72 / 0)

用法: python my_preproc.py
"""
import hashlib
import io
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HEADRT = os.path.join(HERE, "head_rtl")


def pp(text, defs):
    """返回 (存活行 list, 被宏吃掉的行数, 活行中出现的指令行数)."""
    alive, dead, dirs = [], 0, 0
    stack = []            # 每层: [taking_now, seen_else]
    for line in text.split("\n"):
        s = line.lstrip()
        if s.startswith("`ifdef") or s.startswith("`ifndef"):
            name = s.split()[1] if len(s.split()) > 1 else ""
            neg = s.startswith("`ifndef")
            parent_ok = all(st[0] for st in stack)
            taking = (name in defs) != neg
            stack.append([parent_ok and taking, False])
            dirs += 1
            continue
        if s.startswith("`elsif"):
            if stack:
                stack[-1][1] = True
                parent_ok = all(st[0] for st in stack[:-1])
                name = s.split()[1] if len(s.split()) > 1 else ""
                stack[-1][0] = parent_ok and (name in defs)
            dirs += 1
            continue
        if s.startswith("`else"):
            if stack:
                sup = stack.pop()
                stack.append([all(st[0] for st in stack) and not sup[1], True])
            dirs += 1
            continue
        if s.startswith("`endif"):
            if stack:
                stack.pop()
            dirs += 1
            continue
        if all(st[0] for st in stack):
            alive.append(line)
        else:
            dead += 1
    assert not stack, "unbalanced ifdef in file"
    return alive, dead, dirs


def load(p):
    with io.open(p, "r", encoding="utf-8", errors="replace", newline="") as f:
        return f.read()


def sha(s):
    return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()


def diffstat(a, b):
    import difflib
    d = list(difflib.unified_diff(a, b, lineterm="", n=0))
    add = sum(1 for l in d if l.startswith("+") and not l.startswith("+++"))
    rem = sum(1 for l in d if l.startswith("-") and not l.startswith("---"))
    return add, rem


def main():
    ok = True
    for fn, macro in (("tcp_tx_frame.v", "TCP_TX_OVL"), ("app_pattern.v", "P7B_10G")):
        w = load(os.path.join(ROOT, "rtl", fn))
        h = load(os.path.join(HEADRT, fn))
        wa, wd, wdir = pp(w, set())
        ha, hd, hdir = pp(h, set())
        wa2, wd2, _ = pp(w, {macro})
        same = (wa == ha)
        print("=" * 72)
        print("%-16s  工作区 %d 行 / HEAD %d 行" % (fn, len(w.split("\n")), len(h.split("\n"))))
        print("  A) 宏关: 活行 %d vs %d ; 被吃 %d vs %d ; 指令行 %d vs %d"
              % (len(wa), len(ha), wd, hd, wdir, hdir))
        print("     逐行相同 = %s   (sha256 %s vs %s)"
              % (same, sha("\n".join(wa))[:16], sha("\n".join(ha))[:16]))
        if not same:
            add, rem = diffstat(ha, wa)
            print("     !! 不同: +%d / -%d 行" % (add, rem))
            ok = False
        add, rem = diffstat(ha, wa2)
        print("  B) 宏开 (%s): 活行 %d (差 +%d / -%d vs HEAD 宏关活行)"
              % (macro, len(wa2), add, rem))
        if not (add > 0 and rem == 0):
            print("     !! 期望 纯插入 (rem == 0)")
            ok = False
    print("=" * 72)
    print("MY_PREPROC: %s" % ("OK" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
