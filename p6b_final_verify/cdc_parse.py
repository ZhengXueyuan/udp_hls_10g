#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cdc_parse.py — 把 Vivado `report_cdc -details` 的报告拆成**可逐条解释**的清单:
  ① 顶部 Summary (ID/严重度/条数)
  ② 每个 (Source Clock → Destination Clock, CDC Type) 段的条数
  ③ 每段里的 **cell 模式** (把 [n] 下标折掉 ⇒ 同一束多比特只占一行), 便于与
     P6B_SPEC §3 的跨域清单逐条对照。

用法: python cdc_parse.py <cdc.rpt>
"""
import collections
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SUMMARY = re.compile(r"^(CDC-\d+)\s+(\w+)\s+(\d+)\s+(.+?)\s*$")
SRC = re.compile(r"^Source Clock:\s*(\S+)")
DST = re.compile(r"^Destination Clock:\s*(\S+)")
CTYPE = re.compile(r"^CDC Type:\s*(.+?)\s*$")
# "  1  CDC-15  Warning   Clock enable controlled ...   0  Asynch Clock Groups  src  dst"
ROW = re.compile(r"^\s*(\d+)\s+(CDC-\d+)\s+(\w+)\s+.*?(\d+)\s+(\S.*?)\s{2,}(\S+)\s{2,}(\S+)\s*$")


def collapse(name):
    """把 mem_reg_64_127_7_13 / op[12] / reg[7]_i_3 之类折成模式"""
    n = re.sub(r"\[\d+\]", "[*]", name)
    n = re.sub(r"_\d+_\d+_\d+_\d+/", "/*/", n)
    return n


def main():
    path = sys.argv[1]
    lines = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()

    print("=" * 100)
    print("① SUMMARY")
    print("=" * 100)
    for ln in lines:
        m = SUMMARY.match(ln.strip())
        if m:
            print("  %-8s %-9s %5s  %s" % (m.group(1), m.group(2), m.group(3), m.group(4)))

    # 段
    secs = []      # [src, dst, ctype, rows[]]
    cur = None
    for ln in lines:
        ms = SRC.match(ln)
        if ms:
            cur = {"src": ms.group(1), "dst": None, "type": None, "rows": []}
            secs.append(cur)
            continue
        if cur is None:
            continue
        md = DST.match(ln)
        if md and cur["dst"] is None:
            cur["dst"] = md.group(1)
            continue
        mc = CTYPE.match(ln)
        if mc and cur["type"] is None:
            cur["type"] = mc.group(1)
            continue
        mr = ROW.match(ln)
        if mr:
            cur["rows"].append(mr.groups())

    print()
    print("=" * 100)
    print("② 每个 (源域 → 目的域, CDC 类型) 段")
    print("=" * 100)
    pair = collections.Counter()
    for s in secs:
        if not s["rows"]:
            continue
        key = (s["src"], s["dst"] or "?", s["type"] or "?")
        pair[key] += len(s["rows"])
    for k in sorted(pair, key=lambda k: -pair[k]):
        print("  %-14s -> %-22s %-42s %6d" % (k[0], k[1], k[2][:42], pair[k]))

    print()
    print("=" * 100)
    print("③ 每段内的 cell 模式 (下标已折叠) —— 与 P6B_SPEC §3 逐条对照用")
    print("=" * 100)
    for s in secs:
        if not s["rows"]:
            continue
        agg = collections.Counter()
        ids = collections.Counter()
        for r in s["rows"]:
            _no, cid, _sev, _d, _exc, src, dst = r
            agg[(collapse(src), collapse(dst))] += 1
            ids[cid] += 1
        print("\n--- %s -> %s  [%s]  条数=%d  ID:%s" %
              (s["src"], s["dst"], s["type"], len(s["rows"]),
               dict(ids)))
        for (a, b), n in agg.most_common(40):
            print("      %5d x  %-62s -> %s" % (n, a, b))
        if len(agg) > 40:
            print("      ... 另有 %d 种模式未列" % (len(agg) - 40))

    print()
    print("=" * 100)
    print("④ 全局: 所有出现过的 CDC 源/目的**模块前缀** (顶层例化名)")
    print("=" * 100)
    mods = collections.Counter()
    for s in secs:
        for r in s["rows"]:
            for nm in (r[5], r[6]):
                parts = nm.split("/")
                if parts and parts[0]:
                    mods[parts[0].split("[")[0]] += 1
    for k, v in mods.most_common(30):
        print("  %-40s %6d" % (k, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
