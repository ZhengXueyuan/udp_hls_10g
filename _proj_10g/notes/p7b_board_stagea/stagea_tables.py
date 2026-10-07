#!/usr/bin/env python3
"""stagea_tables.py -- Stage A 逐跑表 (机械从原始件算, 不手抄)。

输入: run_*.txt (j6 台架全量 stdout) + ss_STG_*.log
输出: 每跑一行; 另打 (g') 的 rho 与两段速率判据 (e)/(f) 的判定值。
用法: python stagea_tables.py <run_dir> [<prefix>]
"""
import glob
import os
import re
import sys

CAP_BOARD = 1111.1     # TCP app 结构天花板 Mbps (0.889 B/拍 x 156.25 MHz)
MOD32 = 1 << 32


def w_of(txt, tag, word):
    cur = None
    for line in txt.splitlines():
        if line.startswith("SNAP_BEGIN "):
            cur = line.split()[1]
            continue
        if line.startswith("SNAP_END"):
            cur = None
            continue
        if cur is None or not cur.endswith("_" + tag):
            continue
        m = re.match(r"^W(\d+)\s+0x\S+\s+\S+\s+(0x[0-9a-fA-F]+)$", line)
        if m and int(m.group(1)) == word:
            return int(m.group(2), 16)
    return None


def parse_run(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    r = {"file": os.path.basename(path)}
    m = re.search(r"^PACE_BPS=(\d+)", txt, re.M)
    r["pace"] = int(m.group(1)) if m else None
    m = re.search(r"SRC_SUM tx_bytes=(\d+) rx_bytes=(\d+) dur_s=([\d.]+) tx_Mbps=([\d.]+)", txt)
    if m:
        r["tx_bytes"] = int(m.group(1))
        r["dur"] = float(m.group(3))
        r["tx_mbps"] = float(m.group(4))
    else:
        r["tx_bytes"] = r["dur"] = r["tx_mbps"] = None
    for tag in ("pre", "t0", "t1", "post"):
        for w in (5, 53, 54, 61, 62):
            r["%s_W%d" % (tag, w)] = w_of(txt, tag, w)
    r["d53"] = (r["post_W53"] - r["pre_W53"]) % MOD32 if None not in (r["post_W53"], r["pre_W53"]) else None
    r["d53_t"] = (r["t1_W53"] - r["t0_W53"]) % MOD32 if None not in (r["t1_W53"], r["t0_W53"]) else None
    r["d5_t"] = (r["t1_W5"] - r["t0_W5"]) % MOD32 if None not in (r["t1_W5"], r["t0_W5"]) else None
    r["d61"] = (r["t1_W61"] - r["t0_W61"]) % MOD32 if None not in (r["t1_W61"], r["t0_W61"]) else None
    r["d54"] = (r["t1_W54"] - r["t0_W54"]) % MOD32 if None not in (r["t1_W54"], r["t0_W54"]) else None
    r["ratio53"] = (r["d53"] / r["tx_bytes"]) if (r["d53"] is not None and r["tx_bytes"]) else None
    r["brd_mbps"] = (r["d53_t"] * 8 * 156.25e6 / r["d5_t"] / 1e6) if r.get("d5_t") else None
    gm = re.search(r"J6_GEOM_OK NW=(\d+) BID=(\S+)", txt)
    r["geom"] = ("%s/%s" % (gm.group(1), gm.group(2))) if gm else "MISSING"
    m = re.search(r"CARRIER=(\d)", txt)
    r["carrier"] = m.group(1) if m else "?"
    return r


def pace_of(fn):
    m = re.search(r"_([Pp]\w+?)_r(\d)", os.path.basename(fn))
    return m.group(1).upper() if m else "?"


d = sys.argv[1]
pref = sys.argv[2] if len(sys.argv) > 2 else "run_"
files = sorted(glob.glob(os.path.join(d, pref + "*.txt")))

print("%-30s %-12s %-13s %-10s %-10s %-8s %-9s %-12s %-8s %-6s" % (
    "RUN", "PACE(B/s)", "tx_bytes", "tx_Mbps", "cap", "rho", "dW53/txb", "brd_Mbps(t0t1)", "dW61", "geom"))
for f in files:
    r = parse_run(f)
    pace = r["pace"] if r["pace"] is not None else -1
    cap = CAP_BOARD if pace == 0 else min(CAP_BOARD, 8 * pace / 1e6)
    rho = (r["tx_mbps"] / cap) if (r["tx_mbps"] and cap) else None
    print("%-30s %-12s %-13s %-10s %-10.1f %-8s %-9s %-12s %-8s %-6s" % (
        r["file"], pace, r["tx_bytes"], r["tx_mbps"], cap,
        "%.5f" % rho if rho else "-",
        "%.6f" % r["ratio53"] if r["ratio53"] else "-",
        "%.3f" % r["brd_mbps"] if r["brd_mbps"] else "-",
        r["d61"], r["geom"]))
    # 判定
    if rho is not None:
        e = (pace is not None and pace <= 100e6)
        f_ = (pace is not None and (pace >= 160e6 or pace == 0))
        tags = []
        if e:
            tags.append("(e)%s" % ("OK" if r["tx_mbps"] >= 0.95 * 8 * pace / 1e6 else "FAIL"))
        if f_:
            tags.append("(f)%s" % ("OK" if r["tx_mbps"] >= 1000 else "FAIL"))
        tags.append("(g')%s" % ("OK" if 0.95 <= rho <= 1.05 else "FAIL"))
        tags.append("(d)%s" % ("OK" if r["ratio53"] and abs(r["ratio53"] - 1) <= 0.005 else "FAIL/BAD"))
        print("      " + "  ".join(tags))
