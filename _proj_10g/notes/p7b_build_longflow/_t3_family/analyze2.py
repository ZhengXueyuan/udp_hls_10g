# -*- coding: utf-8 -*-
"""T3 分析 (续): 归一化近临界剖面 (以各档自身 WNS 为基准) + 域切分。只读。"""
import os, re
from collections import Counter

BASE = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out"
WNS = {"C1": 0.014, "S1": 0.016, "S2": 0.052, "S3": 0.052, "R1": -0.035}


def load(rung):
    pf = os.path.join(BASE, rung, "worst2000_%s.txt" % rung)
    paths = []
    for l in open(pf, encoding="utf-8", errors="replace"):
        if l.startswith("#") or not l.strip():
            continue
        p = l.rstrip("\n").split("|")
        if len(p) < 5:
            continue
        paths.append({"slack": float(p[0]), "src": p[1], "dst": p[2], "lv": p[3], "dly": float(p[4])})
    return paths


def is_pcie(p):
    return p["src"].startswith("u_pcie") or p["dst"].startswith("u_pcie")


print("=== 归一化近临界剖面: 以各档自身 WNS 为基准 (源 = worst2000 dump) ===")
print("档   WNS      dump末条    n(WNS+0.01) n(+0.02) n(+0.05) n(+0.10) n(+0.20)   [DP域 only: 同上]")
rows = {}
for r in ["C1", "S1", "S2", "S3", "R1"]:
    ps = load(r)
    last = ps[-1]["slack"]
    w = WNS[r]
    def cnt(d, only_dp=False):
        return sum(1 for p in ps if p["slack"] < w + d and (not only_dp or not is_pcie(p)))
    deltas = [0.01, 0.02, 0.05, 0.10, 0.20]
    allc = [cnt(d) for d in deltas]
    dpc = [cnt(d, True) for d in deltas]
    ok = "OK" if w + 0.20 <= last else "!!CAP!!"
    print("%-4s %+.3f   %+.3f(%s)   %-4d %-4d %-4d %-4d %-4d      [DP: %-4d %-4d %-4d %-4d %-4d]" %
          (r, w, last, ok, allc[0], allc[1], allc[2], allc[3], allc[4], dpc[0], dpc[1], dpc[2], dpc[3], dpc[4]))
    rows[r] = (allc, dpc)

print()
print("=== 绝对阈值 (全设计, 含 PCIe 域) —— 与 T3|CNT 交叉核对 ===")
CNT = {"C1": (175, 489, 1445, 4096), "S1": (3, 7, 50, 1039), "S2": (0, 68, 318, 2376),
       "S3": (0, 4, 16, 759), "R1": (140, 297, 959, 3550)}
for r in ["C1", "S1", "S2", "S3", "R1"]:
    ps = load(r)
    d = [sum(1 for p in ps if p["slack"] < t) for t in (0.05, 0.10, 0.20, 0.50)]
    print("%-4s  dump: %-5d %-5d %-5d %-5d   T3|CNT: %-5d %-5d %-5d %-5d" % (r, d[0], d[1], d[2], d[3], *CNT[r]))

print()
print("=== 各族 (源寄存器范式) 跨档对照: 每档在该族内的最差 slack + 级数 ===")
FAMS = {
    "A: bank_rdy_reg[0]": "u_tcp_tx/bank_rdy_reg[0]",
    "B: retx_active_reg": "u_tcp_tx/retx_active_reg",
    "C: recv_first_reg": "u_tcp_tx/recv_first_reg",
    "D: c_snd_una_reg[14][8]": "u_app_ctrl/c_snd_una_reg[14][8]",
    "E: ack_pend_r_reg_replica": "u_tcp_tx/ack_pend_r_reg_replica",
    "G: c_snd_una_reg[11][5]": "u_app_ctrl/c_snd_una_reg[11][5]",
    "H: u_app_udp/u_txf/dout_reg[64]": "u_app_udp/u_txf/dout_reg[64]",
    "I: u_app_udp/u_txf/dout_reg[70]": "u_app_udp/u_txf/dout_reg[70]",
}
hdr = "%-32s" % "族(源)" + "".join("%-22s" % r for r in ["C1", "S1", "S2", "S3", "R1"])
print(hdr)
for label, pat in FAMS.items():
    cells = []
    for r in ["C1", "S1", "S2", "S3", "R1"]:
        ps = [p for p in load(r) if re.sub(r"/[CD]$", "", p["src"]) == pat]
        if not ps:
            cells.append("-")
        else:
            mn = min(ps, key=lambda p: p["slack"])
            cells.append("%+.3f(lv%s,n%d)" % (mn["slack"], mn["lv"], len(ps)))
    print("%-32s" % label + "".join("%-22s" % c for c in cells))
