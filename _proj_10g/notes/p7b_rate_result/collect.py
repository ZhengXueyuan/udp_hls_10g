#!/usr/bin/env python3
"""collect.py -- 汇总所有轮次的读数, 并用**两种口径**各算一遍 (P7B_RATE_RESULT.md 的表由此生成)。

两种口径必须并列，因为它们是这次测量的核心发现：
  · 计划口径 (P7B_RATE_MEASURE_PLAN.md §2.2): 载荷 1472 B / 线长 1518 B / 193.24 拍
  · 实测口径 (本次 pcap 逐帧 + 板侧 W43/W20 实测): 载荷 1464 B / 线长 1510 B / 192.00 拍
"""
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
W32 = 1 << 32
F = 156.25e6


def d32(a, b):
    return (b - a) % W32


def load_snap(p):
    W, gen = {}, None
    for ln in open(p, encoding="utf-8", errors="replace"):
        m = re.match(r"^W(\d+)\s+(0[xX][0-9a-fA-F]{1,8})$", ln.strip())
        if m:
            W[int(m.group(1))] = int(m.group(2), 16)
        m = re.match(r"^GEN\s+(\d+)\s+(\d+)$", ln.strip())
        if m:
            gen = (int(m.group(1)), int(m.group(2)))
    return W, gen


def load_nic(p):
    d = {}
    for ln in open(p, encoding="utf-8", errors="replace"):
        m = re.match(r"^([A-Za-z][A-Za-z0-9_.\-]*)\s+(\d+)$", ln.strip())
        if m:
            d[m.group(1)] = int(m.group(2))
    return d


def main():
    cases = sys.argv[1:]
    print("%-6s %8s %10s %10s %9s %9s %9s %9s %9s" %
          ("case", "dt(s)", "dW20", "fps", "载荷1464", "载荷1472", "拍/帧", "d_dma/d_board", "d_mac/d_board"))
    for c in cases:
        d = c.rsplit("/", 1)[0] if "/" in c else "."
        base = c if c.endswith("snap_a.txt") else c + "/snap_a.txt"
        base_b = base.replace("snap_a", "snap_b")
        na, nb = base.replace("snap_a", "nic_a"), base_b.replace("snap_b", "nic_b")
        Wa, ga = load_snap(base)
        Wb, gb = load_snap(base_b)
        A, B = load_nic(na), load_nic(nb)
        dW5, dW24, dW20, dW43 = d32(Wa[5], Wb[5]), d32(Wa[24], Wb[24]), d32(Wa[20], Wb[20]), d32(Wa[43], Wb[43])
        dt = dW5 / F
        fps = dW20 / dt
        fps_dp = dW20 / (dW24 / F)
        dmac = B.get("port_rx_packets", 0) - A.get("port_rx_packets", 0)
        ddma = B.get("rx-0.rx_packets", 0) - A.get("rx-0.rx_packets", 0)
        dnd = B.get("port_rx_nodesc_drops", 0) - A.get("port_rx_nodesc_drops", 0)
        print("%-6s %8.4f %10d %10.1f %9.3f %9.3f %9.3f %9.5f %9.5f" %
              (c.split("/")[0], dt, dW20, fps, fps * 1464 * 8 / 1e9, fps * 1472 * 8 / 1e9,
               dW43 / dW20, ddma / dW20, dmac / dW20))
        print("       └ fps_DP=%9.1f (域差 %+.4f%%)  d_mac=%d d_dma=%d d_nd=%d  Δcrc=%d Δbad=%d Δovf=%d  W13=%d W21=%d W41=%d W42=%d" %
              (fps_dp, 100 * (fps_dp / fps - 1), dmac, ddma, dnd,
               B.get("rx_eth_crc_err", 0) - A.get("rx_eth_crc_err", 0),
               B.get("port_rx_bad", 0) - A.get("port_rx_bad", 0),
               B.get("port_rx_overflow", 0) - A.get("port_rx_overflow", 0),
               d32(Wa[13], Wb[13]), d32(Wa[21], Wb[21]), d32(Wa[41], Wb[41]), d32(Wa[42], Wb[42])))


if __name__ == "__main__":
    main()
