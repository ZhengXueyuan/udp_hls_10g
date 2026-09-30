#!/usr/bin/env python3
"""split_probe.py -- 把 rate_probe.sh 的输出拆成 rate_calc.py 要的规范文本。

rate_probe.sh 输出里的判据相关内容:
  NIC_T0_<TAG> <wall>            ← NIC 采样开始时刻
  <key> <dec>                    ← NIC 计数 (port_rx_*, rx-N.*)
  NIC_T1_<TAG> <wall>
  SNAP_T0_<TAG> <wall>           ← 触发写之前
  GEN <g0> <g1>                  ← L3: 必须恰好 +1
  SNAP_T1_<TAG> <wall>           ← 锁存完成
  MAGIC/BID/MARKER/UNIMPL/W0..W50
  ===== BLOCK A ===== / B

输出: snap_a.txt / snap_b.txt / nic_a.txt / nic_b.txt (rate_calc 能直接吃) + 一段摘要
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def parse(path):
    blocks = {"A": {"w": {}, "nic": {}, "gen": None, "t": {}},
              "B": {"w": {}, "nic": {}, "gen": None, "t": {}}}
    cur = None
    for ln in open(path, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln.startswith("===== BLOCK"):
            cur = ln.split()[2]
            continue
        if cur is None:
            continue
        if ln.startswith("SNAP_T0_"):
            blocks[cur]["t"]["snap_t0"] = float(ln.split()[1])
        elif ln.startswith("SNAP_T1_"):
            blocks[cur]["t"]["snap_t1"] = float(ln.split()[1])
        elif ln.startswith("NIC_T0_"):
            blocks[cur]["t"]["nic_t0"] = float(ln.split()[1])
        elif ln.startswith("NIC_T1_"):
            blocks[cur]["t"]["nic_t1"] = float(ln.split()[1])
        elif ln.startswith("LATCHA_WALL"):
            blocks[cur]["t"]["dump_a_end"] = float(ln.split()[1])
        elif ln.startswith("GEN "):
            p = ln.split()
            blocks[cur]["gen"] = (int(p[1]), int(p[2]))
        elif ln.startswith("W") and " " in ln:
            k, v = ln.split(None, 1)
            if k[1:].isdigit():
                blocks[cur]["w"][k[1:]] = v
        elif ln.startswith(("MAGIC ", "BID ", "MARKER ", "UNIMPL ")):
            k, v = ln.split(None, 1)
            blocks[cur]["w"][k] = v
        elif " " in ln:
            k, v = ln.split(None, 1)
            if v.isdigit() and not k.startswith(("ROUTE", "PAD_SLEEP", "PROBE")):
                blocks[cur]["nic"][k] = v
    return blocks


def main():
    path, outdir = sys.argv[1], sys.argv[2]
    b = parse(path)
    os.makedirs(outdir, exist_ok=True)
    for tag in ("A", "B"):
        d = b[tag]
        with open(os.path.join(outdir, "snap_%s.txt" % tag.lower()), "w", encoding="utf-8") as f:
            g = d["gen"]
            f.write("GEN %d %d\n" % (g[0], g[1]))
            for k in ("MAGIC", "BID", "MARKER", "UNIMPL"):
                if k in d["w"]:
                    f.write("%s %s\n" % (k, d["w"][k]))
            for i in range(51):
                f.write("W%d %s\n" % (i, d["w"][str(i)]))
        with open(os.path.join(outdir, "nic_%s.txt" % tag.lower()), "w", encoding="utf-8") as f:
            for k, v in d["nic"].items():
                f.write("%s %s\n" % (k, v))
    # 摘要（时刻用，给"同刻"与窗口宽度判定）
    for tag in ("A", "B"):
        t = b[tag]["t"]
        print("block %s: gen=%s nic=[%.3f, %.3f] snap_latch=%.3f  nic_w=%.4f s" %
              (tag, b[tag]["gen"], t.get("nic_t0", 0), t.get("nic_t1", 0),
               t.get("snap_t1", 0), t.get("nic_t1", 0) - t.get("nic_t0", 0)))


if __name__ == "__main__":
    main()
