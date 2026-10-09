#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#=============================================================================
# extract_failfamily.py -- 从 wrapper_p4_timing_summary_routed.rpt 里抠出:
#   (1) Design Timing Summary 12 个数 + 报告自述结论
#   (2) 每时钟段的 "Setup/Hold/PW : N Failing Endpoints, Worst Slack ..." 块
#   (3) 所有 "Slack (VIOLATED)" 路径块 (Slack / Path Type / Source / Destination
#       / Logic Levels) —— 报告里默认只列 top-N 条 (通常 10), 记下 N 以防误读
# 用法: python extract_failfamily.py <rpt> [<rpt> ...]
# 只读, 不写任何文件。
#=============================================================================
import re, sys, os


def one(path):
    print("=" * 100)
    print("RPT:", path)
    if not os.path.exists(path):
        print("  MISSING")
        return
    txt = open(path, encoding="utf-8", errors="replace").read()

    # (1) Design Timing Summary
    i = txt.find("Design Timing Summary")
    if i < 0:
        print("  NO Design Timing Summary")
    else:
        m = re.search(r"^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$",
                      txt[i:], re.M)
        if m:
            g = m.groups()
            print(f"  SUMMARY setup WNS={g[0]} TNS={g[1]} fail={g[2]}/{g[3]}")
            print(f"  SUMMARY hold  WHS={g[4]} THS={g[5]} fail={g[6]}/{g[7]}")
            print(f"  SUMMARY pulse WPWS={g[8]} TPWS={g[9]} fail={g[10]}/{g[11]}")
        else:
            print("  SUMMARY row not parsed")
        print("  SELF-VERDICT:", "constraints met" if "All user specified timing constraints are met." in txt
              else "NOT met")

    # (2) per clock pair failing-endpoint blocks
    pat = re.compile(r"^From Clock:\s+(\S+)\s*\n\s*To Clock:\s+(\S+)\s*\n\s*\n"
                     r"Setup :\s+(\d+)\s+Failing Endpoints,\s+Worst Slack\s+(-?\d+\.\d+)ns,\s+Total Violation\s+(-?\d+\.\d+)ns\s*\n"
                     r"Hold  :\s+(\d+)\s+Failing Endpoints,\s+Worst Slack\s+(-?\d+\.\d+)ns,\s+Total Violation\s+(-?\d+\.\d+)ns\s*\n"
                     r"PW    :\s+(\d+)\s+Failing Endpoints,\s+Worst Slack\s+(-?\d+\.\d+)ns,\s+Total Violation\s+(-?\d+\.\d+)ns",
                     re.M)
    rows = pat.findall(txt)
    print(f"  PER-CLOCK-PAIR BLOCKS: {len(rows)} (只列有失败的)")
    for r in rows:
        if int(r[2]) or int(r[5]) or int(r[8]):
            print(f"    {r[0]} -> {r[1]}: setup fail={r[2]} wns={r[3]} tns={r[4]} | "
                  f"hold fail={r[5]} whs={r[6]} | PW fail={r[8]} wpws={r[9]}")

    # (3) violated path blocks (top-N in the report)
    blocks = re.split(r"Slack \(VIOLATED\)\s*:\s*", txt)[1:]
    print(f"  VIOLATED PATH BLOCKS LISTED: {len(blocks)} (报告默认只列 top-N)")
    for b in blocks:
        slack = b.split("ns", 1)[0].strip()
        src = re.search(r"Source:\s+(\S+)", b)
        dst = re.search(r"Destination:\s+(\S+)", b)
        pt = re.search(r"Path Type:\s+(.+?)\s*$", b, re.M)
        ll = re.search(r"Logic Levels:\s+(\d+)\s*(\(.*?\))?\s*$", b, re.M)
        # 逻辑级数明细可能另起一行
        ll2 = re.search(r"Logic Levels:\s+(\d+)", b)
        print(f"    slack={slack:>8}  type={(pt.group(1) if pt else '?'):<28} "
              f"levels={(ll2.group(1) if ll2 else '?')}")
        print(f"      SRC={(src.group(1) if src else '?')}")
        print(f"      DST={(dst.group(1) if dst else '?')}")
    print()


if __name__ == "__main__":
    for p in sys.argv[1:]:
        one(p)
