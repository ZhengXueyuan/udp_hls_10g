#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mktable2.py -- 从 ANALYZE_ALL.txt (JSON) + runs/*.txt + runs/*_dump.txt 生成并列读数表"""
import json
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
txt = open("ANALYZE_ALL.txt", encoding="utf-8").read()
J = {r["tag"]: r for r in json.loads(txt.split("JSON_SUM: ")[1])}
RCV = {"R1A": 8388608, "R1B": 8388608, "PRE_R1A": 8388608, "Q11K": 11680, "Q11KD": 11680,
       "Q5K": 5840, "Q5KD": 5840, "Q5KD2": 5840, "Q2K": 2920, "Q2K3": 2920,
       "Q2KD": 2920, "Q2KD2": 2920, "Q2K2": 2920, "Q1K": 1460, "Q1KD": 1460}
ORDER = ["R1A", "R1B", "PRE_R1A", "Q11K", "Q11KD", "Q5K", "Q5KD", "Q5KD2",
         "Q2K", "Q2K3", "Q2KD", "Q2KD2", "Q2K2", "Q1K", "Q1KD"]


def sink(tag):
    for ln in open("runs/%s.txt" % tag, encoding="utf-8", errors="replace"):
        if ln.startswith("SINK_CONN 0 "):
            return ln.strip()
    return ""


hdr = ("| run | rcvbuf | tcpdump | sink | sink Mbps | fps plat med | W_eff | dW67/dW66 | dW68(k) | "
       "dTcpOutSegs_lo | ratio | d_ssh | conn-dW68 | U_board | L_full[us/ev] | L'_full[us/seg] | L_iv med | L[us/win] |")
print(hdr)
print("|" + "---|" * 18)
for t in ORDER:
    r = J.get(t)
    if not r:
        continue
    s = r.get("snmp") or {}
    sk = sink(t)
    m = re.search(r"(OK|STALL|POLL_TIMEOUT)", sk)
    mb = re.search(r"mism_bytes=(\d+)", sk)
    st = (m.group(1) if m else "?") + ("+MISM" if mb and int(mb.group(1)) > 0 else "")
    mbps = re.search(r"Mbps=([\d.]+)", sk)
    do = s.get("d_out_lo")
    dsh = s.get("d_ssh")
    dconn = (do - dsh) if (do is not None and dsh is not None) else None
    L = r["dW66"] / (156.25 * r["dW68"]) if r["dW68"] else None
    Lp = r["dW66"] / (156.25 * do) if do else None
    ev = r.get("ev_per_frm") or 0
    we = r["W_eff"] or 0
    Lwin = (r["L_med_iv"] or 0) * ev * (we / 1518.0) if (r["L_med_iv"] and ev and we) else None
    print("| **%s** | %s | %s | %s | %s | %.1f | %s | %.6f | %d (k=0) | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
        t, RCV[t], "Y" if "D" in t else "-", st, mbps.group(1) if mbps else "-",
        r["fps_med_plat"] or 0, r["W_eff"], r["cap_share"] or 0, r["dW68"],
        do if do else "-", ("%.6f" % (r["dW68"] / do)) if do else "-",
        dsh if dsh is not None else "(v1:n/a)",
        (dconn - r["dW68"]) if dconn else "-", r.get("U_board"),
        ("%.6f" % L) if L else "-", ("%.6f" % Lp) if Lp else "-",
        ("%.6f" % r["L_med_iv"]) if r["L_med_iv"] else "-", ("%.4f" % Lwin) if Lwin else "-"))

print()
print("### tcpdump win witness (point sampling, 80 pkts/point)")
for t in ORDER:
    try:
        raw = open("runs/%s_dump.txt" % t, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    pts = re.findall(r"-- point (\d+):\n(?:n=(\d+) min=(\d+) med=(\d+) max=(\d+)|\([^)]*\))", raw)
    got = [(int(a), int(b), int(c), int(d), int(e)) for a, b, c, d, e in pts if b]
    ts = re.findall(r"PHASE2_P(\d+)_DONE rc=(\d+) at ([\d.]+)", raw)
    tin = [float(x[2]) for x in ts]
    print("- **%s**: valid points %d/12 | n per point %s | win min=%s med=%s max=%s | point times %.2f -> %.2f (span %.1f s)" % (
        t, len(got), sorted(set(x[1] for x in got)), sorted(set(x[2] for x in got)),
        sorted(set(x[3] for x in got)), sorted(set(x[4] for x in got)),
        min(tin) if tin else 0, max(tin) if tin else 0, (max(tin) - min(tin)) if tin else 0))
