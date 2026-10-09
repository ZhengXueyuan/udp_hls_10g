# -*- coding: utf-8 -*-
"""对比同一端点对在两档里的路径单元序列 (结构 vs 摆放)。只读。
report_timing 的实际排版是 "两行一条": 类型行 + 数值/资源行 (或其上带 net(...) 行)。"""
import re, os
BASE = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\_t3_family\out"

NUM = re.compile(r'^\s+(?:net\s*\([^)]*\)\s+)?(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+([rf])\s+(\S.*)$')
TYPE = re.compile(r'^\s+\S+\s+(\S+)\s+\(Prop_[^)]*\)\s*$')
NETLINE = re.compile(r'^\s+net\s*\([^)]*\)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\S.*)$')


def rows(path):
    """返回 [(kind, label, resource)] 顺序表; kind = cell/net"""
    out = []
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    # 从 "Netlist Resource(s)" 表头之后找第一条分隔线作为数据段起点
    hdr = next((i for i, l in enumerate(lines) if "Netlist Resource(s)" in l), None)
    if hdr is None:
        return out
    seps = [i for i, l in enumerate(lines) if i > hdr and l.strip().startswith("---")]
    if len(seps) < 3:
        return out
    seg = lines[seps[1] + 1: seps[2]]   # 第 2 段 = 数据通路 (第 1 段 = 时钟通路)
    pending = None
    for l in seg:
        m = TYPE.match(l)
        if m:
            pending = m.group(1)
            continue
        m = NETLINE.match(l)
        if m:
            out.append(("net", "net", m.group(3).strip()))
            pending = None
            continue
        m = NUM.match(l)
        if m:
            res = m.group(4).strip()
            if pending:
                out.append(("cell", pending, res))
            else:
                out.append(("cell", "?", res))
            pending = None
    return out


def key(r):
    """去掉位置/实例序号噪声后的逻辑标识: 用 resource 名 (net 名可能带 _n_ 后缀差异)"""
    return r[2]


for a, b in [("C1", "S3"), ("C1", "S2"), ("C1", "S1"), ("C1", "R1")]:
    for fam in ["A_exact", "B_exact"]:
        fa = os.path.join(BASE, a, "fam_%s_%s.rpt" % (a, fam))
        fb = os.path.join(BASE, b, "fam_%s_%s.rpt" % (b, fam))
        if not (os.path.exists(fa) and os.path.exists(fb)):
            continue
        ra, rb = rows(fa), rows(fb)
        print("=" * 110)
        print("## %s vs %s [%s]: rows %d vs %d (cell+net)" % (a, b, fam, len(ra), len(rb)))
        same = sum(1 for i in range(min(len(ra), len(rb))) if key(ra[i]) == key(rb[i]))
        print("   same-position same-resource rows = %d / %d" % (same, min(len(ra), len(rb))))
        for i in range(max(len(ra), len(rb))):
            la = "%s %s" % (ra[i][1], ra[i][2]) if i < len(ra) else "-"
            lb = "%s %s" % (rb[i][1], rb[i][2]) if i < len(rb) else "-"
            mark = "  " if (i < len(ra) and i < len(rb) and key(ra[i]) == key(rb[i])) else " *"
            print("%s %-52s | %s" % (mark, la[:52], lb[:52]))
