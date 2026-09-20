#!/usr/bin/env python
"""parse_timing.py - extract top-N setup/hold paths + summary from a Vivado
report_timing_summary .rpt file. Read-only helper for P5e verification.

Usage: python parse_timing.py <report.rpt> [n]
"""
import re
import sys


def parse(path, n=10):
    with open(path, "r", errors="replace") as fh:
        lines = fh.readlines()

    # --- summary block ---
    summary = {}
    for i, ln in enumerate(lines):
        if ln.strip().startswith("WNS(ns)"):
            vals = lines[i + 2].split()
            keys = ["WNS", "TNS", "TNS_FEP", "TNS_TEP", "WHS", "THS",
                    "THS_FEP", "THS_TEP", "WPWS", "TPWS", "TPWS_FEP",
                    "TPWS_TEP"]
            for k, v in zip(keys, vals):
                summary[k] = v
            break

    # --- path blocks ---
    sections = {"setup": [], "hold": []}
    cur = None
    for i, ln in enumerate(lines):
        if ln.startswith("Max Delay Paths"):
            cur = "setup"
            continue
        if ln.startswith("Min Delay Paths"):
            cur = "hold"
            continue
        if cur is None:
            continue
        m = re.match(r"^Slack \((MET|VIOLATED)\)\s*:\s*(-?[\d.]+)ns", ln)
        if not m:
            continue
        blk = lines[i:i + 14]
        src = dst = grp = None
        for b in blk:
            s = b.strip()
            if s.startswith("Source:") and src is None:
                src = s[len("Source:"):].strip()
                # continuation line (cell type on next line)
                nxt = blk[blk.index(b) + 1].strip()
                if nxt and not nxt.startswith(("Destination:", "Source:")):
                    src = src + " " + nxt
            elif s.startswith("Destination:") and dst is None:
                dst = s[len("Destination:"):].strip()
                nxt = blk[blk.index(b) + 1].strip()
                if nxt and not nxt.startswith(("Path Group:", "Destination:")):
                    dst = dst + " " + nxt
            elif s.startswith("Path Group:"):
                grp = s[len("Path Group:"):].strip()
            elif s.startswith("Data Path Delay:"):
                dly = s[len("Data Path Delay:"):].strip()
            elif s.startswith("Logic Levels:"):
                lvl = s[len("Logic Levels:"):].strip()
        sections[cur].append({
            "slack": float(m.group(2)),
            "state": m.group(1),
            "src": src,
            "dst": dst,
            "grp": grp,
            "delay": locals().get("dly", ""),
            "levels": locals().get("lvl", ""),
        })
    return summary, sections


# Known 2-level cones (parent/child instance names) for wrapper_p4 -> accurate
# cone attribution. Longest prefix wins.
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
    """Extract the cone instance name from a netlist path (longest known match)."""
    if not sig:
        return "?"
    s = sig.split("(")[0].strip()
    parts = s.split("/")
    if len(parts) >= 2 and "/".join(parts[:2]) in CONES_2:
        return "/".join(parts[:2])
    return parts[0] if parts and parts[0] else "?"


def main():
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    summary, sec = parse(path)
    print("=" * 100)
    print("FILE: " + path)
    print("=" * 100)
    order = ["WNS", "TNS", "TNS_FEP", "TNS_TEP", "WHS", "THS", "THS_FEP",
             "THS_TEP", "WPWS", "TPWS", "TPWS_FEP", "TPWS_TEP"]
    print("  ".join("%s=%s" % (k, summary.get(k, "?")) for k in order))
    for kind in ("setup", "hold"):
        print("\n--- %s top %d ---" % (kind.upper(), n))
        print("%-4s %-9s %-42s %-42s" % ("#", "slack", "SRC (cone)", "DST (cone)"))
        for i, p in enumerate(sec[kind][:n], 1):
            s = p["src"] or "?"
            d = p["dst"] or "?"
            s = s[:38] + " [" + cone(s) + "]"
            d = d[:38] + " [" + cone(d) + "]"
            print("%-4d %-9.3f %-52s %-52s" % (i, p["slack"], s, d))
        # cone histogram (all paths parsed)
        from collections import Counter
        print("  [cone hist %s] %s" % (
            kind,
            Counter((cone(p["src"]), cone(p["dst"])) for p in sec[kind]).most_common()))


if __name__ == "__main__":
    main()
