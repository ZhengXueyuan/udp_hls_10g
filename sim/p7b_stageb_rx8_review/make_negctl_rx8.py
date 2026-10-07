#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_negctl_rx8.py -- 从当前 rtl/app_pattern.v 派生**负对照变异件** (期望判据变红).

三个变异都在 **RX 侧** (TX 一字不动 ⇒ 它们的 TX dump 必须与 A 逐字节相同):

  m1: 状态推进退化  xs_next8(rx_lfsr) -> xs_next(rx_lfsr)
      ⇒ 每拍只推进 1 步 (期望字本身仍由 xs_word8 给出) ⇒ **第二个满字起期望序列全错**
      ⇒ 期望红在: RX0/RX1/I0/I1/RATE 的 mismatch 判据 (rxb 不变, mm 爆)。

  m2: 逐 lane 比对砍成"只比 lane0" (rx_bad_v[7:1] 钉 0)
      ⇒ 满字里 lane1..7 的翻位抓不到
      ⇒ 期望红在: I0 的 mm==4 与 I1 的 mm==11 (但 dump 完全不变)。

  m3: 满字判据从 (rx_kn == 8) 放宽成 (rx_kn != 0) —— 尾字回落路径被拆掉
      ⇒ 尾字被当满字比 (8 lane) 且按 8 字节计数 ⇒ rxb 与 mm 同时错
      ⇒ 期望红在: RX0/RX1 的 rxb==7875 mm==0 与 I1 的 26/11。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "app_pattern.v")
OUT = os.path.join(HERE, "negctl")

s = io.open(SRC, encoding="utf-8", newline="").read()

# ---- m1: M^8 退化 ----
a1 = "    wire [63:0] rx_lfsr_8   = xs_next8(rx_lfsr);      // 期望序列推进 8 步"
b1 = "    wire [63:0] rx_lfsr_8   = xs_next(rx_lfsr);       // NEGCTL-M1: M^8 退化"
assert s.count(a1) == 1, "m1 anchor: %d" % s.count(a1)
m1 = s.replace(a1, b1)

# ---- m2: 只比 lane0 ----
pat = re.compile(r"    assign rx_bad_v\[(\d)\] = \(rx_tdata\[[^\]]+\]\s*!== "
                 r"rx_exp_word\[[^\]]+\]\);\r?\n")
hits = pat.findall(s)
assert sorted(hits) == [str(k) for k in range(8)], "m2 lanes found: %s" % hits


def _m2_repl(m):
    lane = int(m.group(1))
    if lane == 0:
        return m.group(0)
    return "    assign rx_bad_v[%d] = 1'b0;   // NEGCTL-M2: only lane0\n" % lane


m2 = pat.sub(_m2_repl, s)
assert m2.count("NEGCTL-M2") == 7, m2.count("NEGCTL-M2")

# ---- m3: 尾字回落路径拆掉 ----
a3 = "    wire        rx_wide     = (rxs == 2'd0) && rx_tvalid && (rx_kn == 4'd8) && !ev_up;"
b3 = "    wire        rx_wide     = (rxs == 2'd0) && rx_tvalid && (rx_kn != 4'd0) && !ev_up;  // NEGCTL-M3"
assert s.count(a3) == 1, "m3 anchor: %d" % s.count(a3)
m3 = s.replace(a3, b3)

# ---- m4: 去掉 ev_up 让位 (硬化前的写法) ----
a4 = "    wire        rx_wide     = (rxs == 2'd0) && rx_tvalid && (rx_kn == 4'd8) && !ev_up;"
b4 = "    wire        rx_wide     = (rxs == 2'd0) && rx_tvalid && (rx_kn == 4'd8);  // NEGCTL-M4"
assert s.count(a4) == 1, "m4 anchor: %d" % s.count(a4)
m4 = s.replace(a4, b4)

os.makedirs(OUT, exist_ok=True)
io.open(os.path.join(OUT, "app_pattern_m1.v"), "w",
        encoding="utf-8", newline="").write(m1)
io.open(os.path.join(OUT, "app_pattern_m2.v"), "w",
        encoding="utf-8", newline="").write(m2)
io.open(os.path.join(OUT, "app_pattern_m3.v"), "w",
        encoding="utf-8", newline="").write(m3)
io.open(os.path.join(OUT, "app_pattern_m4.v"), "w",
        encoding="utf-8", newline="").write(m4)
print("NEGCTL OK: m1 (M8->M) + m2 (lane0 only) + m3 (no tail fallback) "
      "+ m4 (no ev_up yield) -> %s" % OUT)
sys.exit(0)
