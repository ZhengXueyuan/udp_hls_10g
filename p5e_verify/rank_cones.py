#!/usr/bin/env python
"""rank_cones.py - aggregate a Vivado report_timing (max_paths N) file by cone.

Usage: python rank_cones.py <setup_400.rpt> <hold_400.rpt>
"""
import re
import sys
from collections import Counter, OrderedDict

# Longest-known-prefix cone list (parent/child) for wrapper_p4.
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


def parse(path):
    lines = open(path, errors="replace").readlines()
    out = []
    for i, ln in enumerate(lines):
        m = re.match(r"^Slack \((MET|VIOLATED)\)\s*:\s*(-?[\d.]+)ns", ln)
        if not m:
            continue
        blk = lines[i:i + 20]
        rec = {"slack": float(m.group(2)), "state": m.group(1),
               "src": None, "dst": None, "grp": None}
        for j, b in enumerate(blk):
            s = b.strip()
            if s.startswith("Source:") and rec["src"] is None:
                rec["src"] = s[7:].strip()
            elif s.startswith("Destination:") and rec["dst"] is None:
                rec["dst"] = s[12:].strip()
            elif s.startswith("Path Group:"):
                rec["grp"] = s[11:].strip()
        out.append(rec)
    return out


def main():
    for path in sys.argv[1:]:
        recs = parse(path)
        if not recs:
            print("no paths in", path)
            continue
        kind = "SETUP" if "setup" in path.lower() else "HOLD"
        print("=" * 108)
        print("%s  %s   (%d paths, worst %.3f)" % (kind, path, len(recs), recs[0]["slack"]))
        print("=" * 108)
        print("%-4s %-8s %-40s %-40s %s" % ("#", "slack", "SRC", "DST", "group"))
        for i, r in enumerate(recs[:12], 1):
            print("%-4d %-8.3f %-40s %-40s %s" % (
                i, r["slack"],
                (r["src"] or "?")[:38] + " [" + cone(r["src"]) + "]",
                (r["dst"] or "?")[:38] + " [" + cone(r["dst"]) + "]",
                r["grp"] or ""))

        # per-cone worst slack (src cone), full population
        print("\n-- per-cone worst slack (%s), cone = src cone --" % kind)
        best = OrderedDict()
        for r in recs:
            c = cone(r["src"])
            if c not in best or r["slack"] < best[c]:
                best[c] = r["slack"]
        for c, s in sorted(best.items(), key=lambda kv: kv[1])[:25]:
            print("   %-22s worst=%.3f  (paths=%d)" % (
                c, s, sum(1 for r in recs if cone(r["src"]) == c)))

        # family histogram (src->dst cone pair)
        print("\n-- src->dst cone pair histogram --")
        for pair, n in Counter((cone(r["src"]), cone(r["dst"])) for r in recs).most_common(15):
            print("   %-24s -> %-24s  %d" % (pair[0], pair[1], n))

        # explicit 5-new-module + legacy-family rank check
        print("\n-- named-cone rank check --")
        for name in ["u_udp_split", "u_udp_split/u_udp_rx", "u_udp_tx", "u_udp_tx_cfg",
                     "u_app_udp", "u_tx_udp_arb", "u_tcp_tx/u_retx", "u_app_ctrl",
                     "u_app", "u_hls"]:
            hits = [(i + 1, r["slack"]) for i, r in enumerate(recs)
                    if name in (cone(r["src"]), cone(r["dst"]))]
            if hits:
                print("   %-24s first_rank=%-4d worst=%.3f  count=%d" % (
                    name, hits[0][0], min(h[1] for h in hits), len(hits)))
            else:
                print("   %-24s NOT in top %d of this report" % (name, len(recs)))
        print()


if __name__ == "__main__":
    main()
