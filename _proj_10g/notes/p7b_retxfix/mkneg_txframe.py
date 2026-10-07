#!/usr/bin/env python3
# mkneg_txframe.py -- P7B-RETXFIX r5: wrapper63 门新增 t3/t4 臂的负对照变异件生成器
#
# 目的 (牙检): 证明 t3/t4 两条编译臂有牙且宏敏感 ——
#   mut_ovl.v : 在首个 `ifdef TCP_TX_OVL 之后注入语法错
#               => t3 (TCP_TX_OVL 关) 应 **rc=0** (错误在跳过区), t4 (开) 应 rc!=0
#   mut_dp.v  : 在 DP_156MHZ 分支 RTO_LIM 行后注入语法错
#               => t3 与 t4 (都定义 DP_156MHZ) 都应 rc!=0
#   clean.v   : 原文件拷贝 => t4 应 rc=0 (对照, 排除"臂本来就恒 fail")
#
# 锚点缺失 = 硬失败 (exit 2), 不许静默产出 0 变异的空文件。
# 行尾按原文件原样保留 (newline='' 读写), 不改动源码树 (只写 negctl/)。
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
OUT = os.path.join(HERE, "negctl")

JOBS = [
    ("mut_ovl.v", "`ifdef TCP_TX_OVL", "wire negctl_garbage_ovl = ;   // injected syntax error (negctl)"),
    ("mut_dp.v", "parameter integer RTO_LIM  = 12207;",
     "wire negctl_garbage_dp = ;   // injected syntax error (negctl)"),
]


def gen(src_lines, anchor, inject):
    for i, ln in enumerate(src_lines):
        if anchor in ln:
            return src_lines[: i + 1] + ["    " + inject + "\r\n"] + src_lines[i + 1:]
    return None


def main():
    os.makedirs(OUT, exist_ok=True)
    with io.open(SRC, "r", encoding="utf-8", newline="") as f:
        lines = f.readlines()
    # 对照件: 未变异拷贝
    with io.open(os.path.join(OUT, "clean.v"), "w", encoding="utf-8", newline="") as f:
        f.writelines(lines)
    rc = 0
    for name, anchor, inject in JOBS:
        m = gen(lines, anchor, inject)
        if m is None:
            print(f"MKNEG FAIL: anchor not found for {name}: {anchor!r}")
            rc = 2
            continue
        with io.open(os.path.join(OUT, name), "w", encoding="utf-8", newline="") as f:
            f.writelines(m)
        print(f"MKNEG OK {name} (anchor: {anchor})")
    sys.exit(rc)


if __name__ == "__main__":
    main()
