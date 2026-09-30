#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analyze_lat.py -- P7b 分段延迟: 把 probe_lat.tcl 的原始十六进制读数换算成分段延迟

  Run (anaconda):
     C:/Users/zhxue/anaconda3/python.exe _proj_10g/p7b_lat/scripts/analyze_lat.py

  输入: _proj_10g/p7b_lat/p7b_lat_probe_stdout.txt  (probe_lat.tcl 的 stdout)
  输出: stdout 的分段表 + _proj_10g/p7b_lat/p7b_lat_readings.md 的原始表

  ⚠️ 所有算术在这里做 (Python 大整数), **不在 Tcl 里做** —— Vivado 2025.2 的
     Tcl 是 32 位的, `format %d/%X` 对 >2^31 会静默输出 0。
"""
import re, sys, os, math

HERE = os.path.dirname(os.path.abspath(__file__))
LAT  = os.path.dirname(HERE)
TXT  = os.path.join(LAT, "p7b_lat_probe_stdout.txt")

# ---------------------------------------------------------------- 物理常数
# P7A_RESULT.md:210  RATE (bits/wall) = 1.000025e10 bit/s  (fabric/XGMII 侧 64bit)
F_FE   = 1.000025e10 / 64        # = 156.25390625e6 Hz  (CDR 恢复钟 = XGMII 时钟)
# P6B_ACCEPT.md B2b  数据面 156.2585 MHz (W24 自由计数 / 真实墙钟 12.188566 s)
F_DP   = 156.2585e6
# 线上标称比特率 (任务书给的硬下限口径: (8+L)*8/10.3125e9)
LINE_BPS_NOMINAL = 1.03125e10
# 实测线速率 = 实测 fabric 率 × 66/64 (= +0.0025%); 仅用于给出下限的不确定度
LINE_BPS_MEAS    = (1.000025e10) * 66.0 / 64.0

T_FE = 1.0 / F_FE
T_DP = 1.0 / F_DP

M32 = 0xFFFFFFFF

# ---------------------------------------------------------------- 解码表
# rtl/p7b_lat_top.v §6 的 24 字表; 每字 32 位, W0 在 flat 最低位。
# 探针 piN = flat[128N +: 128]; 探针内第 j 个字 (j=0 -> 最低 32 位)
W = {
    0:  "fe_a",      1:  "fe_b",      2:  "dp_vs",    3:  "dp_c",
    4:  "dp_d",      5:  "cal_fe",    6:  "cal_dp",   7:  "dp_cf",
    8:  "pkg_evt_ab",9:  "pkg_evt_c_cf",10:"pkg_evt_d_cal",11:"pkg_flags_len",
    12: "dp_d2",     13: "pkg_evt_vs_d2",14:"pkg_drp_addr",15:"pkg_drp0",
    16: "pkg_drp1",  17: "pkg_drp_to", 18:"dp_e",      19:"dp_e2",
    20: "pkg_evt_e", 21: "cal_fe_b",   22:"cal_dp_c",  23:"pkg_anchors",
}

def word_of(probe_hex, j):
    """probe_hex 是 32 字符的十六进制 (MSB 在前); 第 j 个字 = 从右往左第 j 个 8 字符"""
    h = probe_hex.rjust(32, "0")[-32:]
    return int(h[(3 - j) * 8:(4 - j) * 8], 16)

def hi16(v): return (v >> 16) & 0xFFFF
def lo16(v): return v & 0xFFFF

def s32(a, b):
    """(a-b) 的**有符号** 32 位解释 (真值远小于 2^31, 所以这就是真差)。

    ⚠️ 必须是有符号: 标定锚点有可能落在被测事件**之后** —— 例如 (a) 与 (b)
       之间可能刚好完成一次标定乒乓, 于是 cal_fe_b > fe_a ⇒ 差为负。
       (mod 2^32 当无符号读会得到 ~4.29e9, 直接把结果毁掉。)
    """
    return ((a - b + (1 << 31)) & M32) - (1 << 31)

# ---------------------------------------------------------------- 解析
def parse(path):
    if not os.path.exists(path):
        print("FATAL: %s not found" % path); sys.exit(2)
    cases, cur = {}, None
    order = []
    drp = []
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        m = re.match(r"^LAT_CASE (\S+) len=(\d+) mut_sel=(\d+) mut_n=(\d+) ack=(\d+)", line)
        if m:
            lab = m.group(1)
            cur = {"label": lab, "len": int(m.group(2)), "mut_sel": int(m.group(3)),
                   "mut_n": int(m.group(4)), "ack": int(m.group(5)), "pi": {}}
            cases[lab] = cur; order.append(lab)
            continue
        m = re.match(r"^LAT_HEX (\S+) pi(\d) ([0-9A-Fa-f]+)$", line)
        if m and cur is not None and m.group(1) == cur["label"]:
            cur["pi"][int(m.group(2))] = m.group(3)
            continue
        m = re.match(r"^LAT_DRP addr=([0-9A-Fa-f]+) pi3=([0-9A-Fa-f]+) pi4=([0-9A-Fa-f]+)$", line)
        if m:
            drp.append((m.group(1).upper(), m.group(2), m.group(3)))
    return cases, order, drp

def to_words(pi):
    out = {}
    for n in range(6):
        h = pi.get(n)
        if h is None: return None
        for j in range(4):
            out[4 * n + j] = word_of(h, j)
    return out

# ---------------------------------------------------------------- 主
def main():
    cases, order, drp = {}, [], []
    # 多轮合并: 板级跑了 3 轮 (同一份位流, 每轮都重烧) —— 背景帧是随机的,
    # 合并三轮才能给出"同一帧长"的多个样本。
    runs = [TXT] + [os.path.join(LAT, "board_scratch", "run%d_stdout.txt" % n)
                    for n in (1, 2, 3)]
    for r in runs:
        if not os.path.exists(r):
            continue
        c2, o2, d2 = parse(r)
        tag = "r%d_" % runs.index(r)
        for lab in o2:
            c2[lab]["label"] = tag + lab
            cases[tag + lab] = c2[lab]
            order.append(tag + lab)
        drp += d2
    print("=" * 100)
    print("P7b 分段延迟 -- 换算  (F_FE = %.6f MHz [P7A], F_DP = %.4f MHz [P6B])"
          % (F_FE / 1e6, F_DP / 1e6))
    print("  硬下限口径 = (8+L)*8/%.4e  (标称) ; 实测线速率 = %.6e (+0.0025%%)"
          % (LINE_BPS_NOMINAL, LINE_BPS_MEAS))
    print("=" * 100)

    rows = []
    for lab in order:
        c = cases[lab]
        w = to_words(c["pi"])
        if w is None:
            print("[%s] 探针不完整 -- 跳过" % lab); continue
        r = {}
        r["label"] = lab; r["len_req"] = c["len"]; r["ack"] = c["ack"]
        r["mut_sel"] = c["mut_sel"]; r["mut_n"] = c["mut_n"]
        r["fe_a"] = w[0]; r["fe_b"] = w[1]; r["dp_vs"] = w[2]; r["dp_c"] = w[3]
        r["dp_d"] = w[4]; r["dp_cf"] = w[7]; r["dp_e"] = w[18]; r["dp_e2"] = w[19]
        r["cal_fe"] = w[5]; r["cal_dp"] = w[6]
        r["cal_fe_b"] = w[21]; r["cal_dp_c"] = w[22]
        r["cal_evt_fe_b"] = hi16(w[23]); r["cal_evt_dp_c"] = lo16(w[23])
        r["cal_evt"] = lo16(w[10])
        r["evt_a"] = hi16(w[8]);  r["evt_b"] = lo16(w[8])
        r["evt_c"] = hi16(w[9]);  r["evt_cf"] = lo16(w[9])
        r["evt_d"] = hi16(w[10]); r["evt_vs"] = hi16(w[13]); r["evt_d2"] = lo16(w[13])
        r["evt_e"] = hi16(w[20]); r["evt_e2"] = lo16(w[20])
        r["flags"] = hi16(w[11]); r["fe_len"] = lo16(w[11])
        r["f_snap_ack"]   = r["flags"] & 1
        r["f_fe_cap"]     = (r["flags"] >> 1) & 1
        r["f_busy"]       = (r["flags"] >> 2) & 1
        r["f_laneflags"]  = (r["flags"] >> 6) & 3
        r["drp_to"] = (w[17] >> 2) & 3
        r["drp0_evt"] = hi16(w[15]); r["drp0_do"] = lo16(w[15])
        r["drp1_evt"] = hi16(w[16]); r["drp1_do"] = lo16(w[16])
        r["drp0_addr"] = (w[14] >> 16) & 0x3FF
        r["drp1_addr"] = w[14] & 0x3FF

        # ---- 段延迟 --------------------------------------------------------
        # (a)->(b): FE 域内, 精确
        r["ab_ns"]  = s32(r["fe_b"], r["fe_a"]) * T_FE * 1e9
        # (b)->(c): 跨域, 用**帧时刻**锚点对 (cal_fe_b, cal_dp_c)
        r["bc_ns"]  = (s32(r["dp_c"], r["cal_dp_c"]) * T_DP
                       - s32(r["fe_b"], r["cal_fe_b"]) * T_FE) * 1e9
        # (b)->(vs): 同上
        r["bvs_ns"] = (s32(r["dp_vs"], r["cal_dp_c"]) * T_DP
                       - s32(r["fe_b"], r["cal_fe_b"]) * T_FE) * 1e9
        # (c)->(e SOP): DP 域内, 精确
        r["ce_ns"]  = s32(r["dp_e"], r["dp_c"]) * T_DP * 1e9
        # (e SOP)->(e TLAST): DP 域内 (udp_split 内部把整帧吐完的时长)
        r["ee2_ns"] = s32(r["dp_e2"], r["dp_e"]) * T_DP * 1e9
        # (c)->(e TLAST)
        r["ce2_ns"] = s32(r["dp_e2"], r["dp_c"]) * T_DP * 1e9
        # (a)->(e TLAST) = **(B) 首字节 -> 整帧交付**
        r["ae2_ns"] = (s32(r["dp_e2"], r["cal_dp_c"]) * T_DP
                       - s32(r["fe_a"], r["cal_fe_b"]) * T_FE) * 1e9
        # 该帧长下的线上串行化时间 (硬下限)
        r["bound_ns"] = (8 + r["fe_len"]) * 8.0 / LINE_BPS_NOMINAL * 1e9
        r["A_ns"] = r["ae2_ns"] - r["bound_ns"]     # (A) = (B) - 串行化
        r["pair_ok"] = (r["evt_a"] == r["evt_b"] == r["evt_c"] == r["evt_e"] == r["evt_e2"])
        rows.append(r)

    hdr = ("%-11s %5s %5s %3s %3s | %7s %7s %7s %7s %7s | %8s %8s %8s | %s"
           % ("case", "Lreq", "Lfe", "ms", "mn", "a->b", "b->c", "c->e", "e->e2",
              "c->e2", "(B)a->e2", "(A)=(B)-s", "bound", "evt(a,b,c,e,e2) pair"))
    print(hdr); print("-" * len(hdr))
    for r in rows:
        print("%-11s %5d %5d %3d %3d | %7.2f %7.2f %7.2f %7.2f %7.2f | %8.2f %8.2f %8.2f | %s %s"
              % (r["label"], r["len_req"], r["fe_len"], r["mut_sel"], r["mut_n"],
                 r["ab_ns"], r["bc_ns"], r["ce_ns"], r["ee2_ns"], r["ce2_ns"],
                 r["ae2_ns"], r["A_ns"], r["bound_ns"],
                 (r["evt_a"], r["evt_b"], r["evt_c"], r["evt_e"], r["evt_e2"]),
                 "OK" if r["pair_ok"] else "MISMATCH"))

    # ---- 只保留"帧长核对通过 + 8 个 tap 计数一致"的样本 --------------------
    # ⚠️ 必须排除**变异例**: 它们故意把某一段推迟了 mut_n 拍, 混进来会把拟合斜率带偏。
    good = [r for r in rows if r["ack"] == 1 and r["pair_ok"]
            and r["fe_len"] == r["len_req"] and r["mut_sel"] == 0]
    print("\n==== 干净样本 (ack=1 + 计数一致 + fe_len==请求长度): %d 条 ====" % len(good))
    bylen = {}
    for r in good:
        bylen.setdefault(r["fe_len"], []).append(r)
    print("%6s %5s | %-22s %-22s %-22s %-22s" %
          ("L", "n", "(B) 首字节->整帧交付", "(A)=(B)-线上串行化", "a->b / b->c / c->e(SOP)",
           "e(SOP)->e(TLAST)"))
    for L in sorted(bylen):
        g = bylen[L]
        def stat(f):
            v = [f(x) for x in g]
            return (min(v), sum(v) / len(v), max(v))
        b = stat(lambda x: x["ae2_ns"]); a = stat(lambda x: x["A_ns"])
        ab = stat(lambda x: x["ab_ns"]); bc = stat(lambda x: x["bc_ns"])
        ce = stat(lambda x: x["ce_ns"]); ee = stat(lambda x: x["ee2_ns"])
        print("%6d %5d | %8.2f [%7.2f,%7.2f] %8.2f [%7.2f,%7.2f] %6.2f/%6.2f/%6.2f %8.2f [%7.2f,%7.2f]"
              % (L, len(g), b[1], b[0], b[2], a[1], a[0], a[2],
                 ab[1], bc[1], ce[1], ee[1], ee[0], ee[2]))
    # 硬下限校验
    print("\n---- 硬下限校验 (B) >= (8+L)*8/10.3125e9 ----")
    allok = True
    for r in rows:
        if r["ack"] != 1:
            continue
        if r["ae2_ns"] < r["bound_ns"]:
            allok = False
            print("   FAIL %-16s (B)=%.2f < bound=%.2f" % (r["label"], r["ae2_ns"], r["bound_ns"]))
    print("   %s (%d 条 ack=1 全部通过)" % ("PASS" if allok else "FAIL",
          len([r for r in rows if r["ack"] == 1])))

    # ---- (B) 对帧长的仿射拟合 (只用干净样本) ------------------------------
    print("\n---- (B) 对帧长的仿射拟合 (只用干净样本) ----")
    if len(bylen) >= 2:
        xs = [float(L) for L in sorted(bylen)]
        ys = [sum(x["ae2_ns"] for x in bylen[L]) / len(bylen[L]) for L in sorted(bylen)]
        n = len(xs); sx = sum(xs); sy = sum(ys)
        sxx = sum(x * x for x in xs); sxy = sum(x * y for x, y in zip(xs, ys))
        den = n * sxx - sx * sx
        slope = (n * sxy - sx * sy) / den
        icept = (sy - slope * sx) / n
        th = 8.0 / LINE_BPS_NOMINAL * 1e9
        print("   slope  = %.6f ns/byte   线上标称 = %.6f ns/byte   比 = %.4f"
              % (slope, th, slope / th))
        print("   intercept(L=0) = %.2f ns  (8B 前导的串行化 = %.2f ns)"
              % (icept, 8.0 * th))
        print("   SOP->SOP 流水之和 (a->b + b->c + c->e) = %.2f ns"
              % (sum(r["ab_ns"] + r["bc_ns"] + r["ce_ns"] for r in good) / len(good)))

    # ---- 变异检验 ---------------------------------------------------------
    # 参考 = **同一帧长 (158) 的未变异干净样本**的均值 (变异例会自己把自己排除在
    # `good` 之外, 所以这里另取一组)。
    print("\n---- 变异 (观测链上的可编程延迟, 参考 = L=158 无变异样本均值) ----")
    refset = [r for r in rows if r["ack"] == 1 and r["pair_ok"] and r["fe_len"] == 158
              and r["mut_sel"] == 0]
    if refset:
        rab = sum(r["ab_ns"] for r in refset) / len(refset)
        rbc = sum(r["bc_ns"] for r in refset) / len(refset)
        print("   ref n=%d  a->b=%.2f  b->c=%.2f" % (len(refset), rab, rbc))
        print("   %-12s %4s %4s %4s | %9s %9s | %9s %9s"
              % ("case", "msel", "mn", "Lfe", "D(a->b)", "期望 a->b", "D(b->c)", "期望 b->c"))
        for r in rows:
            if r["mut_sel"] == 0 or r["mut_n"] == 0:
                continue
            exp = r["mut_n"] * T_FE * 1e9
            eab = exp if r["mut_sel"] in (5,) else 0.0
            ebc = exp if r["mut_sel"] in (2, 3) else 0.0
            print("   %-12s %4d %4d %4d | %+9.2f %9.2f | %+9.2f %9.2f"
                  % (r["label"], r["mut_sel"], r["mut_n"], r["fe_len"],
                     r["ab_ns"] - rab, eab, r["bc_ns"] - rbc, ebc))

    # ---- flags / 健康 -----------------------------------------------------
    print("\n---- 健康位 ----")
    for r in rows:
        print("   %-11s ack=%d fe_cap_seen=%d busy=%d lane_flags=%d cal_evt=%d"
              " anchor_evt(fe=%d dp=%d) drp_to=%d"
              % (r["label"], r["f_snap_ack"], r["f_fe_cap"], r["f_busy"],
                 r["f_laneflags"], r["cal_evt"], r["cal_evt_fe_b"],
                 r["cal_evt_dp_c"], r["drp_to"]))

    # ---- DRP --------------------------------------------------------------
    if drp:
        print("\n---- DRP 扫描 (%d 条) ----" % len(drp))
        print("   addr   ch0_evt ch0_do   ch1_evt ch1_do   addr0 addr1")
        seen = {}
        for a, p3, p4 in drp:
            w3 = [word_of(p3, j) for j in range(4)]
            w4 = [word_of(p4, j) for j in range(4)]
            e0, d0 = hi16(w3[3]), lo16(w3[3])
            e1, d1 = hi16(w4[0]), lo16(w4[0])
            ad0 = (w3[2] >> 16) & 0x3FF
            ad1 = w3[2] & 0x3FF
            seen.setdefault((e0, d0, e1, d1), []).append(a)
            print("   %s  %5d   %04X     %5d   %04X     %03X   %03X"
                  % (a, e0, d0, e1, d1, ad0, ad1))

    print("\nDONE")

if __name__ == "__main__":
    main()
