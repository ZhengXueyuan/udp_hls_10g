#!/usr/bin/env python
"""p6_report.py - P6 gate-B controlled experiment: side-by-side comparison of the
8.000ns control (t8p0) and the 6.400ns run (t6p4).  Read-only.

Usage: python p6_report.py [out_dir]      (default: D:/repo/ECO/udp_hls_10g/p6_verify)
"""
import os
import re
import sys
from collections import Counter, OrderedDict

OUT = sys.argv[1] if len(sys.argv) > 1 else "D:/repo/ECO/udp_hls_10g/p6_verify"
TAGS = ["t8p0", "t6p4"]

# Longest-known-prefix cone list, copied verbatim from p5e_verify/rank_cones.py
# (same convention as the P5d/P5e worst-400 cone ranking).
CONES_2 = {
    "u_tcp_tx/u_retx", "u_tcp_tx/u_ackq", "u_tcp_tx/u_csum", "u_tcp_tx/u_fifo",
    "u_udp_split/u_udp_rx", "u_udp_split/u_uf",
    "u_udp_tx/u_csum", "u_udp_tx/u_fifo",
    "u_slow_rx/u_ff", "u_slow_rx/u_ofifo",
    "u_slow_cfg/u_fifo", "u_slow_tx/u_ififo", "u_slow_tx/u_wf",
    "u_hls/u_fifo", "u_app_ctrl/u_evfifo",
    "u_tcp_echo/u_cq", "u_tcp_echo/u_fifo",
    "u_mac_rx/u_crc", "u_mac_rx/u_fifo",
    "u_mac_tx/u_crc", "u_mac_tx/u_fifo",
    "u_cam/u_fifo", "u_app/u_fifo",
}


def cone(sig):
    if not sig:
        return "?"
    s = sig.split("(")[0].strip()
    parts = s.split("/")
    if len(parts) >= 2 and "/".join(parts[:2]) in CONES_2:
        return "/".join(parts[:2])
    return parts[0] if parts and parts[0] else "?"


def rd(path):
    if not os.path.exists(path):
        return None
    return open(path, errors="replace").read().splitlines()


def parse_summary(path):
    lines = rd(path)
    if lines is None:
        return None
    keys = ["WNS", "TNS", "TNS_FEP", "TNS_TEP", "WHS", "THS", "THS_FEP",
            "THS_TEP", "WPWS", "TPWS", "TPWS_FEP", "TPWS_TEP"]
    for i, ln in enumerate(lines):
        if ln.strip().startswith("WNS(ns)"):
            vals = lines[i + 2].split()
            return dict(zip(keys, vals))
    return None


def parse_paths(path):
    """Return list of dicts for each 'Slack (MET|VIOLATED)' block."""
    lines = rd(path)
    if lines is None:
        return []
    out = []
    for i, ln in enumerate(lines):
        m = re.match(r"^Slack \((MET|VIOLATED)\)\s*:\s*(-?[\d.]+)ns", ln)
        if not m:
            continue
        blk = lines[i:i + 16]
        rec = {"slack": float(m.group(2)), "state": m.group(1), "src": "", "dst": "",
               "grp": "", "delay": "", "logic": "", "levels": "", "skew": ""}
        for j, b in enumerate(blk):
            s = b.strip()
            if s.startswith("Source:") and not rec["src"]:
                rec["src"] = s[7:].strip()
                nxt = blk[j + 1].strip() if j + 1 < len(blk) else ""
                if nxt and not nxt.startswith(("Destination:", "Source:")):
                    rec["src"] += " " + nxt
            elif s.startswith("Destination:") and not rec["dst"]:
                rec["dst"] = s[12:].strip()
                nxt = blk[j + 1].strip() if j + 1 < len(blk) else ""
                if nxt and not nxt.startswith(("Path Group:", "Destination:")):
                    rec["dst"] += " " + nxt
            elif s.startswith("Path Group:"):
                rec["grp"] = s[11:].strip()
            elif s.startswith("Data Path Delay:"):
                rec["delay"] = s[16:].strip()
            elif s.startswith("Logic Levels:"):
                rec["levels"] = s[14:].strip()
            elif s.startswith("Clock Path Skew:"):
                rec["skew"] = s[16:].strip()
        out.append(rec)
    return out


def route_pct(delay):
    m = re.search(r"route\s+([\d.]+)ns\s+\(([\d.]+)%\)", delay or "")
    return (m.group(1), m.group(2)) if m else ("?", "?")


def parse_util(path):
    lines = rd(path)
    if lines is None:
        return None
    res = {}
    for ln in lines:
        m = re.match(r"\|\s*(Slice LUTs|Slice Registers|Block RAM Tile|DSPs|"
                     r"CLB LUTs|CLB Registers|RAMB36/FIFO\*?|RAMB18)\s*\|\s*([\d.]+)", ln)
        if m:
            res.setdefault(m.group(1), m.group(2))
    return res


def parse_clocks(path):
    lines = rd(path)
    if lines is None:
        return None
    res = {}
    for ln in lines:
        m = re.match(r"\s*(\S+)\s+(\{.*?\}|[\d.]+)\s+\S+\s+([\d.]+|N/A)\s", ln + " ")
        if m and m.group(1) not in res:
            res[m.group(1)] = m.group(3)
    return res


def dist(vals):
    if not vals:
        return "no paths"
    vals = sorted(vals)
    n = len(vals)
    q = lambda f: vals[min(n - 1, int(f * n))]
    return ("min=%.3f p25=%.3f med=%.3f p75=%.3f max=%.3f mean=%.3f" %
            (vals[0], q(0.25), q(0.5), q(0.75), vals[-1], sum(vals) / n))


def main():
    print("=" * 108)
    print("P6 GATE B -- controlled experiment report   out_dir=%s" % OUT)
    print("=" * 108)

    # ---------- 1. summary table, side by side ----------
    sums = {t: parse_summary("%s/p6_%s_timing_summary_routed.rpt" % (OUT, t)) for t in TAGS}
    order = ["WNS", "TNS", "TNS_FEP", "WHS", "THS", "THS_FEP", "WPWS", "TPWS_FEP"]
    print("\n[1] TIMING SUMMARY (from *_timing_summary_routed.rpt)")
    print("%-10s %14s %14s %14s" % ("metric", TAGS[0], TAGS[1], "delta(6p4-8p0)"))
    for k in order:
        a = (sums[TAGS[0]] or {}).get(k, "?")
        b = (sums[TAGS[1]] or {}).get(k, "?")
        try:
            d = "%+.3f" % (float(b) - float(a))
        except Exception:
            d = "-"
        print("%-10s %14s %14s %14s" % (k, a, b, d))

    # ---------- 2. clock period evidence ----------
    print("\n[2] CLOCK PERIOD EVIDENCE (from *_clocks.rpt)")
    for t in TAGS:
        lines = rd("%s/p6_%s_clocks.rpt" % (OUT, t))
        if lines is None:
            print("   %s: clocks report MISSING" % t)
            continue
        print("   --- %s ---" % t)
        hdr = False
        for ln in lines:
            if re.match(r"\s*Clock\s+Period", ln):
                hdr = True
                print("   " + ln.rstrip())
                continue
            if hdr and re.match(r"\s*-+", ln):
                print("   " + ln.rstrip())
                continue
            if hdr and ln.strip():
                if re.match(r"\s*[a-zA-Z_]\S*\s+[\d.]+\s", ln):
                    print("   " + ln.rstrip())
                else:
                    break

    # ---------- 3. worst-400 distributions ----------
    print("\n[3] WORST-400 SLACK DISTRIBUTION")
    for kind, fname in (("setup", "setup_400"), ("hold", "hold_400")):
        print("   -- %s --" % kind.upper())
        for t in TAGS:
            recs = parse_paths("%s/p6_%s_%s.rpt" % (OUT, t, fname))
            if not recs:
                print("      %s: no report" % t)
                continue
            sl = [r["slack"] for r in recs]
            nviol = sum(1 for r in recs if r["state"] == "VIOLATED")
            print("      %s: n=%d  violated=%d  %s" % (t, len(recs), nviol, dist(sl)))
            bins = Counter()
            for s in sl:
                bins[int(s // 0.25) * 0.25] += 1
            print("         hist(0.25ns bins): %s" %
                  "  ".join("%.2f:%d" % (k, bins[k]) for k in sorted(bins, reverse=True)))

    # ---------- 4. worst path detail ----------
    print("\n[4] WORST SETUP PATH DETAIL (rank 1..3)")
    for t in TAGS:
        recs = parse_paths("%s/p6_%s_setup_400.rpt" % (OUT, t))
        print("   --- %s ---" % t)
        for i, r in enumerate(recs[:3], 1):
            rn, rp = route_pct(r["delay"])
            print("    #%d slack=%.3f grp=%s levels=%s" % (i, r["slack"], r["grp"], r["levels"]))
            print("        src=%s" % r["src"])
            print("        dst=%s" % r["dst"])
            print("        %s  route=%sns (%s%%)" % (r["delay"], rn, rp))

    # ---------- 5. per-cone grouping (src cone) + failing endpoints ----------
    for kind, fname in (("setup", "setup_400"), ("hold", "hold_400")):
        print("\n[5] PER-CONE WORST SLACK (%s, cone = src hierarchy prefix)" % kind.upper())
        for t in TAGS:
            recs = parse_paths("%s/p6_%s_%s.rpt" % (OUT, t, fname))
            if not recs:
                continue
            best = OrderedDict()
            for r in recs:
                c = cone(r["src"])
                best[c] = min(best.get(c, 99.0), r["slack"])
            top = sorted(best.items(), key=lambda kv: kv[1])[:12]
            print("   --- %s ---" % t)
            for c, s in top:
                n = sum(1 for r in recs if cone(r["src"]) == c)
                print("      %-24s worst=%+.3f  paths=%d" % (c, s, n))

    # ---------- 6. fanout signature of the worst paths ----------
    print("\n[6] NET FANOUT SIGNATURE of worst-400 setup paths (fo= token census)")
    for t in TAGS:
        path = "%s/p6_%s_setup_400.rpt" % (OUT, t)
        lines = rd(path)
        if lines is None:
            continue
        fo = Counter()
        for ln in lines:
            for m in re.finditer(r"fo=(\d+)", ln):
                fo[int(m.group(1))] += 1
        print("   %s: %s" % (t, "  ".join("fo=%d:%d" % (k, fo[k])
                                          for k in sorted(fo, reverse=True)[:10])))

    # ---------- 7. failing endpoint hierarchy histogram ----------
    print("\n[7] FAILING SETUP ENDPOINT HIERARCHY (from *_failing_endpoints.txt)")
    for t in TAGS:
        path = "%s/p6_%s_failing_endpoints.txt" % (OUT, t)
        lines = rd(path)
        if lines is None:
            print("   %s: no census file" % t)
            continue
        recs = []
        for ln in lines:
            if ln.startswith("#") or not ln.strip():
                continue
            p = ln.split()
            if len(p) < 4:
                continue
            recs.append((float(p[0]), p[3]))
        if not recs:
            print("   %s: 0 failing endpoints" % t)
            continue
        h2 = Counter()
        w2 = {}
        for s, ep in recs:
            parts = ep.split("/")
            k2 = "/".join(parts[:2]) if len(parts) > 1 else parts[0]
            k1 = parts[0]
            h2[k2] += 1
            w2[k2] = min(w2.get(k2, 99.0), s)
        print("   --- %s: %d failing endpoints, worst=%.3f ---" % (t, len(recs), min(r[0] for r in recs)))
        for k, n in h2.most_common(20):
            print("      %-28s count=%-6d worst=%+.3f" % (k, n, w2[k]))

    # ---------- 8. utilization ----------
    print("\n[8] UTILIZATION (from *_utilization_routed.rpt)")
    keys = ["Slice LUTs", "Slice Registers", "Block RAM Tile", "DSPs", "RAMB36/FIFO", "RAMB18"]
    for t in TAGS:
        u = parse_util("%s/p6_%s_utilization_routed.rpt" % (OUT, t))
        print("   %s: %s" % (t, u))


if __name__ == "__main__":
    main()
