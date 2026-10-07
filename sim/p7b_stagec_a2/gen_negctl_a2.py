#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_negctl_a2.py -- 从当前 rtl/app_pattern.v (= 已应用 A2) 派生**负对照变异件**,
期望对应判据变红 (每个变异只动一处, 断言锚点命中恰 1 次)。

  m1 (N1): 撤前瞻 —— sent_a 退回旧式基准 (seg_sent)
      ⇒ 消费拍上的"下一个字"判据全部按**当字**算: 帧尾会被多装一个满字
        (尾字被 8 字节整字覆盖) / pw_last 错位 ⇒ **字节流与每帧长度必须错**
      ⇒ 期望红在: oracle (pattern mismatch) 或 frame/byte 记账。

  m2 (N2): 收尾判据改用**前瞻** need_a (naive A2 —— 父 agent 推演的"坑 1")
      ⇒ 收尾与"末字被消费"同拍: 消费块的 seg_sent<=seg_sent+pw_n 会盖掉收尾的
        seg_sent<=0 (且 remain 读到未扣减的旧值) ⇒ 第二帧起整段错位/多一帧
      ⇒ 期望红在: oracle / frame 记账 / 帧长度。

  m3 (N3): 整字装载的 LFSR 推进 M^8 -> M^1 (xs_next8 -> xs_next)
      ⇒ 每个满字只推进 1 步 ⇒ **第二个字起期望序列全错** (字节流变)
      ⇒ 期望红在: oracle (pattern mismatch)。

  m4 (N4): 撤 asm_go 的放宽 (= A1 形态: 消费拍不预取)
      ⇒ **字节流必须与 A/B 逐字节相同** (只是每字多 1 拍), 但拍/帧从 190 变
        ~372 ⇒ 只有"拍/帧判据"变红 —— 证明拍/帧门有牙。
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "app_pattern.v")
OUT = os.path.join(HERE, "negctl")

s = io.open(SRC, encoding="utf-8", newline="").read()

# ---- m1: 撤前瞻 (sent_a 退回旧基准) ----
a1 = "    wire [11:0] sent_a  = seg_sent + (pw_take ? {8'b0, pw_n} : 12'd0);"
b1 = "    wire [11:0] sent_a  = seg_sent;  // NEGCTL-M1: no lookahead"
assert s.count(a1) == 1, "m1 anchor: %d" % s.count(a1)
m1 = s.replace(a1, b1)

# ---- m2: 收尾判据用前瞻 need_a (naive A2) ----
a2 = "                if (need == 4'd0) begin\n"
b2 = "                if (need_a == 4'd0) begin   // NEGCTL-M2: close on lookahead\n"
assert s.count(a2) == 1, "m2 anchor: %d" % s.count(a2)
m2 = s.replace(a2, b2)

# ---- m3: 整字装载只推进 1 步 ----
a3 = "                    if (!bad_frm) tx_lfsr <= xs_next8(tx_lfsr);\n"
b3 = "                    if (!bad_frm) tx_lfsr <= xs_next(tx_lfsr);  // NEGCTL-M3\n"
assert s.count(a3) == 1, "m3 anchor: %d" % s.count(a3)
m3 = s.replace(a3, b3)

# ---- m4: 撤 asm_go 放宽 (A1 形态) ----
a4 = "    wire        asm_go  = active && (!pw_valid || (m_tready && !a2_hold)) && !closing &&\n"
b4 = "    wire        asm_go  = active && !pw_valid && !closing &&  // NEGCTL-M4: no relaxation\n"
assert s.count(a4) == 1, "m4 anchor: %d" % s.count(a4)
m4 = s.replace(a4, b4)

# ---- m5: 填充/装载用**非前瞻** need (退回 need_a 之前的写法) ----
a5 = "    wire        asm_full = asm_go && (bcnt == need_a) && (need_a != 4'd0);"
b5 = "    wire        asm_full = asm_go && (bcnt == need) && (need != 4'd0);  // NEGCTL-M5"
assert s.count(a5) == 1, "m5a anchor: %d" % s.count(a5)
m5 = s.replace(a5, b5)
a6 = "                end else if (bcnt < need_a) begin"
b6 = "                end else if (bcnt < need) begin  // NEGCTL-M5"
assert m5.count(a6) == 1, "m5b anchor: %d" % m5.count(a6)
m5 = m5.replace(a6, b6)

os.makedirs(OUT, exist_ok=True)
for nm, txt in (("app_pattern_m1.v", m1), ("app_pattern_m2.v", m2),
                ("app_pattern_m3.v", m3), ("app_pattern_m4.v", m4),
                ("app_pattern_m5.v", m5)):
    io.open(os.path.join(OUT, nm), "w", encoding="utf-8", newline="").write(txt)
print("NEGCTL OK: m1 (no lookahead) + m2 (close on lookahead) + m3 (M8->M) "
      "+ m4 (no asm_go relaxation = A1) + m5 (fill/load on non-lookahead need) -> %s" % OUT)
sys.exit(0)
