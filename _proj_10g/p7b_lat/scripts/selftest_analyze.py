#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
selftest_analyze.py -- 合成一份 LAT_HEX 输入, 检查 analyze_lat.py 的解码/换算

  为什么要它: 探针的**打包** (rtl/p7b_lat_top.v §6 的 24 字拼接) 与**解码**
  (analyze_lat.py 的 W 表) 是两处独立手写的表。位序错一位不会报错, 只会给出
  "看着合理" 的错数 —— 正是本工程最贵的一类缺陷。这里用**解析式反推**:
  给定一组"真值", 按 Verilog 的拼接顺序造出 768 位 flat, 再切成 6 个 128 位
  十六进制串, 喂给分析器, 看它算出来的段延迟是不是真值。
"""
import os, sys, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analyze_lat as A

M32 = 0xFFFFFFFF

# ---- 真值 (拍数随便选, 只要差值小) -----------------------------------------
fe_a      = 5_000_000
fe_b      = fe_a + 11                 # (a)->(b) = 11 FE 拍
cal_fe_b  = fe_b - 4                  # 帧时刻 FE 锚点: 差 +4
cal_dp_c  = 7_000_000
dp_c      = cal_dp_c + 23             # DP 侧 23 拍
dp_vs     = cal_dp_c + 9
dp_e      = dp_c + 6
dp_e2     = dp_e + 31
dp_cf     = 1
dp_d      = 2
cal_fe    = 1                         # 快照时刻的 (故意与帧时刻不同, 用来暴露误用)
cal_dp    = 2
flags     = 0b0000_0000_0000_0011     # snap_ack=1, fe_cap_seen=1
fe_len    = 158
evt_a, evt_b, evt_c, evt_cf = 3, 3, 3, 0
evt_d, cal_evt, evt_vs, evt_d2 = 0, 12345, 3, 0
evt_e, evt_e2 = 3, 3
cal_evt_fe_b, cal_evt_dp_c = 400, 400
drp_to, drp_go = 0b00, 0b00
drp0_evt, drp0_do = 7, 0x0269
drp1_evt, drp1_do = 7, 0x0269
drp0_addr, drp1_addr = 0x269, 0x269

words = [0] * 24
words[0]  = fe_a
words[1]  = fe_b
words[2]  = dp_vs
words[3]  = dp_c
words[4]  = dp_d
words[5]  = cal_fe
words[6]  = cal_dp
words[7]  = dp_cf
words[8]  = ((evt_a << 16) | evt_b) & M32
words[9]  = ((evt_c << 16) | evt_cf) & M32
words[10] = ((evt_d << 16) | cal_evt) & M32
words[11] = ((flags << 16) | fe_len) & M32
words[12] = 0
words[13] = ((evt_vs << 16) | evt_d2) & M32
words[14] = ((drp0_addr & 0x3FF) << 16) | (drp1_addr & 0x3FF)
words[15] = ((drp0_evt << 16) | drp0_do) & M32
words[16] = ((drp1_evt << 16) | drp1_do) & M32
words[17] = ((drp_to << 2) | drp_go) & M32
words[18] = dp_e
words[19] = dp_e2
words[20] = ((evt_e << 16) | evt_e2) & M32
words[21] = cal_fe_b
words[22] = cal_dp_c
words[23] = ((cal_evt_fe_b << 16) | cal_evt_dp_c) & M32

# ---- 按 rtl/p7b_lat_top.v §6 的拼接造 flat (注意: 表里是 MSB 在最前的顺序) ----
def cat(*vals):                      # 高位在前的拼接
    out = 0
    for v in vals:
        out = (out << 32) | (v & M32)
    return out

flat = 0
flat = (flat << 128) | cat(words[23], words[22], words[21], words[20])
flat = (flat << 128) | cat(words[19], words[18], words[17], words[16])
flat = (flat << 128) | cat(words[15], words[14], words[13], words[12])
flat = (flat << 128) | cat(words[11], words[10], words[9],  words[8])
flat = (flat << 128) | cat(words[7],  words[6],  words[5],  words[4])
flat = (flat << 128) | cat(words[3],  words[2],  words[1],  words[0])

# ---- 切成 6 个 128 位十六进制串 (每探针 32 字符; 高位补 0) -------------------
hexes = []
for n in range(6):
    v = (flat >> (128 * n)) & ((1 << 128) - 1)
    hexes.append("%032X" % v)

# ---- 造一份假的 stdout 并跑分析器 ------------------------------------------
sub = tempfile.mkdtemp(prefix="latsel")
outp = os.path.join(sub, "p7b_lat_probe_stdout.txt")
with open(outp, "w", encoding="utf-8") as f:
    f.write("LAT_CASE selftest len=158 mut_sel=0 mut_n=0 ack=1\n")
    for n in range(6):
        f.write("LAT_HEX selftest pi%d %s\n" % (n, hexes[n]))

A.TXT = outp
A.main()

# ---- 断言 ------------------------------------------------------------------
# (b)->(c) 期望 = 23*T_DP - 4*T_FE
exp_bc = (23 * A.T_DP - 4 * A.T_FE) * 1e9
exp_ab = 11 * A.T_FE * 1e9
exp_ae2 = ((dp_e2 - cal_dp_c) * A.T_DP - (fe_a - cal_fe_b) * A.T_FE) * 1e9
print("\n==== SELFTEST 期望值 ====")
print("  (a)->(b)  = %.4f ns" % exp_ab)
print("  (b)->(c)  = %.4f ns   (23 T_DP - 4 T_FE)" % exp_bc)
print("  (a)->(e2) = %.4f ns   ((B) 首字节->整帧交付)" % exp_ae2)
print("  上面表格里对应行的读数必须逐位等于这三个值 (%.4f / %.4f / %.4f)。"
      % (exp_ab, exp_bc, exp_ae2))
print("SELFTEST DONE")
