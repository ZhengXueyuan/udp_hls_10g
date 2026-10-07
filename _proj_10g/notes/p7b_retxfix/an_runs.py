#!/usr/bin/env python3
"""an_runs.py -- Stage C 下行逐跑表 (从 /tmp/run_STC_DL*.log 原始件机械算)。

规则 (P7B_STAGEB_CRITERIA_FIX.md): 板侧计数器全 32 位; ΔW 一律 mod 2^32;
raw 与 k 落表 (本文件 k 由板外 64 位口径 tx_bytes 反推)。
用法: python an_runs.py <run_STC_DL2.log> [<run_STC_DL3.log> ...]
"""
import re
import sys

M32 = 1 << 32


def snap(txt, tag):
    m = re.search(r"SNAP_BEGIN %s gen=\d+\n(.*?)SNAP_END" % re.escape(tag), txt, re.S)
    d = {}
    if not m:
        return d
    for line in m.group(1).splitlines():
        p = line.split()
        if len(p) >= 4 and p[0].startswith("W"):
            d["W" + p[0][1:]] = int(p[3], 16)
    return d


def phase(txt, name):
    m = re.search(r"### PHASE %s (\d+\.\d+)\n(.*?)(?=### PHASE|$)" % name, txt, re.S)
    if not m:
        return None, {}
    vals = {}
    for k, v in re.findall(r"^\s*(\w+):\s+(\d+)", m.group(2), re.M):
        vals[k] = int(v)
    for k, v in re.findall(r"^(Tcp\w+)\s+(\d+)", m.group(2), re.M):
        vals[k] = int(v)
    return float(m.group(1)), vals


def main():
    hdr = ("%-10s %8s %8s %9s %10s %8s %9s %9s %8s %9s %9s %10s"
           % ("tag", "sinkMbps", "aggMbps", "win_s", "W20", "fps_k", "cyc/frm",
              "payl_Mbps", "W15/W51", "retx_sess", "frm/sess", "nd_drops"))
    print(hdr)
    for path in sys.argv[1:]:
        txt = open(path, encoding="utf-8", errors="replace").read()
        tag = re.search(r"STC_META_TAG=(\S+)", txt)
        tag = tag.group(1) if tag else path
        secs = re.search(r"STC_META_SECS=(\d+)", txt)
        sink = re.search(r"SINK_SUM (.*)", txt)
        sinkm = agg = float("nan")
        if sink:
            m1 = re.search(r"agg_Mbps=([\d.]+)", sink.group(1))
            agg = float(m1.group(1)) if m1 else float("nan")
            # 中位 per-conn Mbps
            vals = sorted(float(x) for x in re.findall(r"SINK_CONN \d+ \S+ .*?Mbps=([\d.]+)", txt))
            sinkm = vals[len(vals) // 2] if vals else float("nan")
        t0 = snap(txt, tag + "_t0")
        t1 = snap(txt, tag + "_t1")
        if not t0 or not t1:
            print("%-10s (no t0/t1 snapshots)" % tag)
            continue
        def d(w):
            return (t1.get(w, 0) - t0.get(w, 0)) % M32
        dW5, dW20, dW43, dW51, dW52, dW15, dW55, dW0 = (d("W%d" % w) for w in (5, 20, 43, 51, 52, 15, 55, 0))
        win = dW5 / 156.25e6
        # 板外 64 位口径反推 k (W51 apps bytes; 本窗 20-30MB < 2^32 但保留规则)
        tx = int(re.search(r"bytes=(\d+)", sink.group(1)).group(1)) if sink else 0
        k51 = round((tx - dW51) / M32) if tx else 0
        pre, post = phase(txt, "nic_pre")[1], phase(txt, "nic_post")[1]
        dn = lambda key: post.get(key, 0) - pre.get(key, 0)
        print("%-10s %8.1f %8.1f %9.4f %10d %8.1f %9.2f %9.1f %8.2f %9d %10.1f %10d"
              % (tag, sinkm, agg, win, dW20, dW20 / win / 1e3, dW43 / dW20 if dW20 else 0,
                 dW51 * 8 / win / 1e6, dW15 / dW51 if dW51 else 0, dW55,
                 (dW20 - dW52) / max(dW55, 1), dn("port_rx_nodesc_drops")))
        print("           raw: W51=%d (k=%d) W52=%d W20=%d W14=%d W15=%d W43=%d W55=%d W0=%d | NIC dpkts=%d dbytes=%d TcpOutSegs=%d"
              % (dW51, k51, dW52, dW20, d("W14"), dW15, dW43, dW55, dW0,
                 dn("port_rx_packets"), dn("port_rx_good_bytes"), dn("TcpOutSegs")))


if __name__ == "__main__":
    main()
