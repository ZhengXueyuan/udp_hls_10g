#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iso_audit.py -- 隔离审计: 把"全系统 TcpOutSegs"拆成 [本连接] + [其它 TCP 流量]

数据源 (同一跑):
  runs/<TAG>_ss.log     台架自带 10 ms 采样器, 每行 = "SS_T <ts> <ss -tinma 输出(| 连接)>"
                        → 本连接的 per-socket segs_out / segs_in (内核按连接口径!)
  runs/<TAG>_snmpseq.log 本轮 0.5 s 连续采样器 → 全系统 TcpInSegs / TcpOutSegs
判据口径:
  · 采样点必须落在同一跑窗内 (取本连接**第一个**与**最后一个**含 segs_out 的样本作窗)
  · 全系统计数在两个样本时刻之间用 snmpseq **线性取整内插** (0.5 s 粒度 ⇒ 误差 ≤1 个样本间隔的流量)
  · 输出: 本连接 segs_out 增量 / 全系统增量 / 差 (= 其它 TCP 流量, 含 ssh 承载本脚本 stdout)
"""
import re
import sys


def load_ss(path):
    """-> [(ts, segs_out, segs_in)]"""
    out = []
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^SS_T ([\d.]+) ", ln)
        if not m:
            continue
        ts = float(m.group(1))
        mo = re.search(r"segs_out:(\d+)", ln)
        mi = re.search(r"segs_in:(\d+)", ln)
        if mo and mi:
            out.append((ts, int(mo.group(1)), int(mi.group(1))))
    return out


def load_seq(path):
    """-> [(ts, insegs, outsegs)]"""
    out = []
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^S ([\d.]+) (\d+) (\d+)$", ln.strip())
        if m:
            out.append((float(m.group(1)), int(m.group(2)), int(m.group(3))))
    return out


def interp(seq, ts):
    """在 seq 里按时间线性取整内插 (取相邻两点, 线性)"""
    if ts <= seq[0][0]:
        return seq[0][2]
    if ts >= seq[-1][0]:
        return seq[-1][2]
    for i in range(1, len(seq)):
        if seq[i][0] >= ts:
            t0, o0 = seq[i - 1][0], seq[i - 1][2]
            t1, o1 = seq[i][0], seq[i][2]
            if t1 == t0:
                return o1
            frac = (ts - t0) / (t1 - t0)
            return int(round(o0 + frac * (o1 - o0)))
    return seq[-1][2]


for tag in sys.argv[1:]:
    ss = load_ss("runs/%s_ss.log" % tag)
    seq = load_seq("runs/%s_snmpseq.log" % tag)
    print("== %s : ss_samples=%d snmpseq_samples=%d" % (tag, len(ss), len(seq)))
    if not ss or not seq:
        print("   (数据缺, 跳过)")
        continue
    t0, so0, si0 = ss[0]
    t1, so1, si1 = ss[-1]
    S0 = interp(seq, t0)
    S1 = interp(seq, t1)
    d_sys = S1 - S0
    d_conn = so1 - so0
    d_other = d_sys - d_conn
    print("   窗: %s  (%.3f s)  样本 %d 个" % (tag, t1 - t0, len(ss)))
    print("   本连接 segs_out: %d -> %d  d=%d" % (so0, so1, d_conn))
    print("   segs_in : %d -> %d  d=%d" % (si0, si1, si1 - si0))
    print("   全系统 TcpOutSegs (内插): %d -> %d  d=%d" % (S0, S1, d_sys))
    if d_conn:
        print("   其它 TCP 流量 = d_sys - d_conn = %d  (占全系统 %.4f%%)" % (d_other, 100.0 * d_other / d_sys))
    print("   ⚠️ 本连接最后样本后还有收尾 (FIN/末 ACK) 未计入 ⇒ d_conn 是**下界**")
