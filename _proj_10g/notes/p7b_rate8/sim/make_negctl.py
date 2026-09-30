#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_negctl.py -- 从当前 rtl/app_udp_pattern.v 派生**负对照变异件** (期望判据变红).

m1 (TX 侧): 把 8 路的推进 M^8 **退化成** M  (xs_next8(tx_lfsr) -> xs_next(tx_lfsr))
    ⇒ 每拍仍推出 lane0..7 的字节, 但状态只推进 1 步 ⇒ 后续字节全错。
    期望: (a) TB 内部 L0/L1 回环失配检查变红; (b) dump 文件 diff 变红。

m2 (RX 侧): 把宽路径的**逐 lane 比对**砍成"只比 lane0" (rx_bad_v[7:1] 钉 0)
    ⇒ 满字里 lane1..7 的翻位抓不到。
    期望: R0 (lane1 注入) 与 R1 (lane7 注入) 的"失配恰 1"判据变红;
          dump 文件 diff 仍绿 (TX 未动) —— 说明两条判据覆盖面不同。
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
SRC = os.path.join(ROOT, "rtl", "app_udp_pattern.v")
OUT = os.path.join(HERE, "negctl")

s = io.open(SRC, encoding="utf-8", newline="").read()

# ---- m1 ----
a1 = "    wire [63:0] tx_lfsr_8 = xs_next8(tx_lfsr);              // 状态推进 8 步"
b1 = "    wire [63:0] tx_lfsr_8 = xs_next(tx_lfsr);               // NEGCTL-M1: M^8 退化"
assert s.count(a1) == 1, "m1 anchor: %d" % s.count(a1)
m1 = s.replace(a1, b1)

# ---- m2 ----
import re

pat = re.compile(r"    assign rx_bad_v\[(\d)\] = i_en && \(cmp_d\[[^\]]+\]\s*!== "
                 r"rx_exp_word\[[^\]]+\]\);\r?\n")
hits = pat.findall(s)
assert sorted(hits) == [str(k) for k in range(8)], "m2 lanes found: %s" % hits


def _m2_repl(m):
    lane = int(m.group(1))
    if lane == 0:
        return m.group(0)
    return "    assign rx_bad_v[%d] = 1'b0;   // NEGCTL-M2: 只比 lane0\n" % lane


m2 = pat.sub(_m2_repl, s)
assert m2.count("NEGCTL-M2") == 7, m2.count("NEGCTL-M2")

os.makedirs(OUT, exist_ok=True)
io.open(os.path.join(OUT, "app_udp_pattern_m1.v"), "w",
        encoding="utf-8", newline="").write(m1)
io.open(os.path.join(OUT, "app_udp_pattern_m2.v"), "w",
        encoding="utf-8", newline="").write(m2)
print("NEGCTL OK: m1 (M^8->M) + m2 (只比 lane0) 已生成于 %s" % OUT)
