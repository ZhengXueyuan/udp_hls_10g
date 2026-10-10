#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mktable.py -- 从 ANALYZE_ALL.txt 的 JSON_SUM 生成并列读数表 (Markdown)
数据源: ANALYZE_ALL.txt (analyze2.py 输出) + runs/*_dump.txt (tcpdump win 见证) + sink 行
"""
import json
import re
import sys

TAGS = ["R1A", "R1B", "PRE_R1A", "Q11K", "Q11KD", "Q5K", "Q5KD", "Q5KD2", "Q2K", "Q2K3",
        "Q2KD", "Q2KD2", "Q2K2", "Q1K", "Q1KD"]
RCV = {"R1A": 8388608, "R1B": 8388608, "PRE_R1A": 8388608, "Q11K": 11680, "Q11KD": 11680,
       "Q5K": 5840, "Q5KD": 5840, "Q5KD2": 5840, "Q2K": 2920, "Q2K3": 2920,
       "Q2KD": 2920, "Q2KD2": 2920, "Q2K2": 2920, "Q1K": 1460, "Q1KD": 1460}
DUMP = {t: t.endswith("D") or t == "Q11KD" for t in TAGS}

txt = open("ANALYZE_ALL.txt", encoding="utf-8").read()
J = {r["tag"]: r for r in json.loads(txt.split("JSON_SUM: ")[1])}


def sink(tag):
    for ln in open("runs/%s.txt" % tag, encoding="utf-8", errors="replace"):
        if ln.startswith("SINK_CONN 0 "):
            return ln.strip()
    return ""


def winstats(tag):
    p = "runs/%s_dump.txt" % tag
    try:
        raw = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    pts = re.findall(r"-- point (\d+):\n(?:n=(\d+) min=(\d+) med=(\d+) max=(\d+)|\([^)]*\))", raw)
    got = [(int(a), int(b), int(c), int(d), int(e)) for a, b, c, d, e in pts if b]
    return got


def sssegs(tag):
    first = last = None
    try:
        for ln in open("runs/%s_ss.log" % tag, encoding="utf-8", errors="replace"):
            m = re.search(r"segs_out:(\d+) segs_in:(\d+)", ln)
            if m:
                if first is None:
                    first = m.groups()
                last = m.groups()
    except OSError:
        pass
    return first, last


print("| 跑 | rcvbuf | dump | sink 结果 | sink Mbps | fps 稳态med | W_eff (W69众数) | dW67/dW66 | dW68 (k) | dTcpOutSegs lo | dW68/dOut | ssh dOut | 本连接−dW68 | U_board | L [µs/事件] | L' [µs/段] |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for t in TAGS:
    r = J.get(t)
    if not r:
        print("| %s | (无) | | | | | | | | | | | | | | |" % t)
        continue
    s = r.get("snmp") or {}
    sk = sink(t)
    m = re.search(r"(OK|STALL|POLL_TIMEOUT)", sk)
    mb = re.search(r"mism_bytes=(\d+)", sk)
    st = m.group(1) if m else "?"
    if mb and int(mb.group(1)) > 0:
        st += "+MISM(%s)" % mb.group(1)
    mbps = re.search(r"Mbps=([\d.]+)", sk)
    d_out = s.get("d_out_lo")
    dconn = (d_out - s["d_ssh"]) if (d_out and s.get("d_ssh") is not None) else None
    L = r.get("L_med_iv") or 0
    Lp = (r["dW66"] / (156.25 * d_out)) if (d_out and r.get("dW66")) else None
    print("| **%s** | %s | %s | %s | %s | %.1f | %s | %.6f | %d (k=?) | %s | %s | %s | %s | %s | %s | %s |" % (
        t, RCV[t], "Y" if DUMP[t] else "-", st, mbps.group(1) if mbps else "-",
        r["fps_med_plat"] or 0, r["W_eff"], r["cap_share"] or 0, r["dW68"],
        d_out if d_out else "-",
        ("%.6f" % (r["dW68"] / d_out)) if d_out else "-",
        s.get("d_ssh"), (dconn - r["dW68"]) if dconn else "-", r.get("U_board"),
        ("%.6f" % L) if L else "-", ("%.6f" % Lp) if Lp else "-"))

print()
print("### tcpdump win 字段见证 (每点 80 包; 只有 dump=Y 的跑有)")
for t in TAGS:
    if not DUMP[t]:
        continue
    g = winstats(t)
    if g is None:
        print("- %s: (无 dump 文件)" % t)
        continue
    ns = [x[0] for x in g]
    mins = [x[2] for x in g]
    meds = [x[3] for x in g]
    maxs = [x[4] for x in g]
    ff = open("runs/%s_dump.txt" % t, encoding="utf-8", errors="replace").read()
    ts = re.findall(r"PHASE2_P(\d+)_DONE rc=(\d+) at ([\d.]+)", ff)
    tin = [float(x[2]) for x in ts]
    print("- **%s**: 有效点 %d/%d; 每点 n=80 (Q5KD 类只 %s); win min=%s med=%s max=%s; 点 0..%d 时间 %.2f→%.2f (%s)" % (
        t, len(g), 12, "1 包" if len(g) == 1 else "80",
        sorted(set(mins)), sorted(set(meds)), sorted(set(maxs)),
        max(ns) if ns else -1, min(tin) if tin else 0, max(tin) if tin else 0,
        "%.1f s 跨度" % (max(tin) - min(tin)) if tin else "-"))
