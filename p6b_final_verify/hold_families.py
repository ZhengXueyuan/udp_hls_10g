#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hold_families.py — 从 report_timing -delay_type min -max_paths 400 的报告里
                   按 **path group (三族)** 汇总 hold slack: 最差 slack + 条数 + 是否全 MET。

用法: python hold_families.py <hold_400.rpt> [topN]

报告形态 (Vivado 2025.2):
    Slack (MET) :              +0.010ns  (arrival time - required time)
      ...
      Path Group:             pcie_axi_aclk
      Path Type:              Hold (Min at Slow Process Corner)
每条路径一块。缺 "Path Group" 行的块按 "(none)" 计, 并**显式报出来** (空读数 != 真 0)。

⚠️ 判别力: 本工具同时给出 "该族的条数" —— 若某族一条都没有, 打印 MISSING 而不是 0
   (避免把"没跑到"读成"没问题")。
"""
import collections
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# "Slack (MET) :             0.010ns"  /  "Slack (VIOLATED) :   -0.123ns"
SLACK = re.compile(r"Slack \((MET|VIOLATED)\)\s*:\s*(-?\+?\d+\.\d+)ns")
GROUP = re.compile(r"^\s*Path Group:\s*(\S+)")
PTYPE = re.compile(r"^\s*Path Type:\s*(.+?)\s*$")


def main():
    path = sys.argv[1]
    topn = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    txt = open(path, "r", encoding="utf-8", errors="replace").read()

    blocks = []           # (slack, violated?, group, ptype)
    cur = {"slack": None, "viol": None, "group": None, "ptype": None}
    for ln in txt.splitlines():
        m = SLACK.search(ln)
        if m:
            if cur["slack"] is not None:
                blocks.append(cur)
            cur = {"slack": float(m.group(2)), "viol": m.group(1) == "VIOLATED",
                   "group": None, "ptype": None}
            continue
        mg = GROUP.match(ln)
        if mg and cur["slack"] is not None and cur["group"] is None:
            cur["group"] = mg.group(1)
            continue
        mp = PTYPE.match(ln)
        if mp and cur["slack"] is not None and cur["ptype"] is None:
            cur["ptype"] = mp.group(1)
    if cur["slack"] is not None:
        blocks.append(cur)

    print("解析到 %d 条 timing path (报告 %s)" % (len(blocks), path))
    if not blocks:
        print("!! 空读数: 一条路径都没解析出来 —— 判据不成立 (不是 0 违例)")
        return 2

    # 只保留 hold 类 (报告是 -delay_type min, 但显式核对)
    hold = [b for b in blocks if b["ptype"] and "hold" in b["ptype"].lower()]
    other = [b for b in blocks if b not in hold]

    by = collections.defaultdict(list)
    for b in blocks:
        by[b["group"] or "(none)"].append(b)

    print("\n%-28s %6s %10s %10s %8s  %s" %
          ("PATH GROUP", "PATHS", "MIN-SLACK", "MAX-SLACK", "VIOLATED", "VERDICT"))
    print("-" * 84)
    for g in sorted(by, key=lambda k: min(b["slack"] for b in by[k])):
        bs = by[g]
        mn = min(b["slack"] for b in bs)
        mx = max(b["slack"] for b in bs)
        nv = sum(1 for b in bs if b["viol"])
        print("%-28s %6d %10.3f %10.3f %8d  %s" %
              (g, len(bs), mn, mx, nv, "ALL MET" if nv == 0 else "** VIOLATED **"))

    print("\n--- 全局 ---")
    print("  hold 路径块: %d ; 非 hold 路径块: %d" % (len(hold), len(other)))
    allmin = min(b["slack"] for b in blocks)
    print("  全部 %d 块里的最差 slack = %+.3f ns (%s)" %
          (len(blocks), allmin,
           "ALL MET" if allmin >= 0 else "VIOLATION PRESENT"))
    print("  任一 VIOLATED 标记 = %s" % any(b["viol"] for b in blocks))

    print("\n--- 各族最差 %d 条的 raw slack ---" % topn)
    for g in sorted(by, key=lambda k: min(b["slack"] for b in by[k])):
        ss = sorted(b["slack"] for b in by[g])[:topn]
        print("  %-28s %s" % (g, ["%+.3f" % s for s in ss]))

    # 三族点名 (P6b 的关键判据): pcie_axi / dp / gmii
    print("\n--- P6b hold 三族点名 ---")
    fam = {"pcie_axi_aclk": None, "dp(数据面 6.400ns)": None, "gmii_clk(前端 8.000ns)": None}
    for g, bs in by.items():
        gl = g.lower()
        if "pcie_axi" in gl:
            fam["pcie_axi_aclk"] = (len(bs), min(b["slack"] for b in bs),
                                    sum(1 for b in bs if b["viol"]))
        elif "gmii" in gl:
            fam["gmii_clk(前端 8.000ns)"] = (len(bs), min(b["slack"] for b in bs),
                                             sum(1 for b in bs if b["viol"]))
    # dp 域: 网名是 g_hw.clk_out0 / dp_clk —— 在 path group 里通常是生成时钟名
    for g, bs in by.items():
        gl = g.lower()
        if "clk_out0" in gl or g == "dp_clk" or "dp_" in gl:
            fam["dp(数据面 6.400ns)"] = (len(bs), min(b["slack"] for b in bs),
                                         sum(1 for b in bs if b["viol"]))
    print("  [所有 path group 名] %s" % sorted(by.keys()))
    for k, v in fam.items():
        if v is None:
            print("  %-26s MISSING —— 该族在 -max_paths %d 的窗口里没有出现" % (k, len(blocks)))
        else:
            print("  %-26s 条数=%-4d 最差=%+.3f ns  违例=%d  %s" %
                  (k, v[0], v[1], v[2], "ALL MET" if v[2] == 0 else "** VIOLATED **"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
