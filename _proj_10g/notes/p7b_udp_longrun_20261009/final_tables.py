#!/usr/bin/env python3
"""final_tables.py -- 把 udp_longrun.sh 的 log 变成交付用的读数表 (七项 + 分窗轨迹 + 自证)。

用法: final_tables.py log_L1.txt [log_L2.txt ...]
只做**搬运与 mod 2^32 还原**, 不改口径; 每条读数都打印原始值。
"""
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
M = 1 << 32

WNAME = {
    41: "mtx_stat_flush_words", 42: "mtx_stat_flush_done", 56: "udpapp_tx_ovf",
    21: "tx_stat_abort", 59: "stx_stat_fifo_ovf", 60: "srx_stat_fifo_ovf",
    13: "udpapp_mismatch", 11: "udpapp_rx_bytes", 45: "txcdc_ovf_cnt", 29: "txwire_stall_cycles",
    3: "rx_stat_crc_err", 4: "rx_stat_drop", 35: "rx_stat_fifo_ovf",
    46: "cls_dbg_stat_ovf", 47: "cls_dbg_stat_route_ovf", 38: "rxcdc_ovf_cnt",
}


def parse_snaps(txt):
    out = {}
    cur = None
    for line in txt.splitlines():
        m = re.match(r"^SNAP_BEGIN (\S+) gen=(\d+)", line)
        if m:
            cur = (m.group(1), int(m.group(2)), {})
            out[m.group(1)] = cur
            continue
        if re.match(r"^SNAP_END", line):
            cur = None
            continue
        m = re.match(r"^W(\d+)\s+\S+\s+(\S+)\s+(0x[0-9a-fA-F]+)", line)
        if m and cur:
            out[cur[0]][2][int(m.group(1))] = int(m.group(3), 16)
    return out


def nic(txt, phase):
    m = re.search(r"### PHASE nic_%s[^\n]*\n(.*?)(?=\n###)" % phase, txt, re.S)
    if not m:
        return {}, "?"
    blk = m.group(1)
    v = {}
    for k in ("port_rx_good_bytes", "port_rx_packets", "port_rx_bad", "rx_eth_crc_err",
              "port_rx_nodesc_drops", "port_rx_overflow", "port_rx_bytes", "port_rx_1024_to_15xx",
              "port_tx_packets", "port_tx_bytes", "rx_ip_hdr_chksum_err", "rx_tcp_udp_chksum_err",
              "rx_frm_trunc", "rx_overlength", "rx_noskb_drops", "rx_nodesc_trunc",
              "rx-0.rx_packets", "rx-1.rx_packets", "rx-2.rx_packets", "rx-3.rx_packets",
              "UdpInDatagrams", "UdpNoPorts", "UdpInErrors", "UdpRcvbufErrors",
              "IcmpOutDestUnreachs", "IpInReceives", "IpOutRequests", "IpInDelivers"):
        mm = re.search(r"^\s*%s:\s*(\d+)" % re.escape(k), blk, re.M)
        if mm:
            v[k] = int(mm.group(1))
    cm = re.search(r"### COALESCE (.*)", blk)
    return v, (cm.group(1) if cm else "?")


def phase_ts(txt, name):
    m = re.search(r"### PHASE %s ([\d.]+)" % re.escape(name), txt)
    return float(m.group(1)) if m else None


def report(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    print("=" * 100)
    print("### %s" % path)
    S = parse_snaps(txt)
    tags = [t for t in S if re.match(r"^.*_s\d+$", t)]
    tags.sort(key=lambda t: int(t.split("_s")[-1]))
    pre = S.get([t for t in S if t.endswith("_pre")][0]) if any(t.endswith("_pre") for t in S) else None
    post = S.get([t for t in S if t.endswith("_post")][0]) if any(t.endswith("_post") for t in S) else None
    w0, w1 = S[tags[0]][2], S[tags[-1]][2]
    gen0, gen1 = S[tags[0]][1], S[tags[-1]][1]
    npts = len(tags)
    # 逐段
    segs = []
    for i in range(npts - 1):
        a, b = S[tags[i]][2], S[tags[i + 1]][2]
        dc = (b[5] - a[5]) % M
        db = (b[9] - a[9]) % M
        df = (b[20] - a[20]) % M
        dw = (b[43] - a[43]) % M
        dt = dc / 156.25e6
        segs.append((dt, db, df, dw, gen0 + i + 1))
    tot = (sum(s[0] for s in segs), sum(s[1] for s in segs), sum(s[2] for s in segs), sum(s[3] for s in segs))
    print("POINTS n=%d gen=%d..%d  gen_step1=%s" % (npts, gen0, gen1, all((S[tags[i + 1]][1] - S[tags[i]][1]) % 65536 == 1 for i in range(npts - 1))))
    print("WINDOW(逐点求和) dt=%.4f s frames=%d bytes=%d payload=%.4f Gbps fps=%.1f P=%.5f" %
          (tot[0], tot[2], tot[1], tot[1] * 8 / tot[0] / 1e9, tot[2] / tot[0], tot[3] / tot[2]))
    print("SEG dt min/max = %.4f / %.4f ; payload 速度集 = %s" %
          (min(s[0] for s in segs), max(s[0] for s in segs),
           sorted(set("%.4f" % (s[1] * 8 / s[0] / 1e9) for s in segs))[:4]))
    # 全窗 raw 差分 (逐点求和已是全窗; raw 用首末点)
    print("FIRST/LAST raw: W5 %#x->%#x  W9 %#x->%#x  W20 %d->%d  W43 %#x->%#x" %
          (w0[5], w1[5], w0[9], w1[9], w0[20], w1[20], w0[43], w1[43]))
    if pre and post:
        A, B = pre[2], post[2]
        print("PRE(gen=%d)/POST(gen=%d) 63 字守卫 (raw, mod 2^32):" % (pre[1], post[1]))
        for w in (56, 21, 41, 42, 59, 60, 13, 11, 45, 29, 3, 4, 35, 38, 46, 47, 12, 10):
            if w in A and w in B:
                raw = (B[w] - A[w]) % M
                print("   W%-3d %-22s A=%#010x B=%#010x Δ(raw)=%d %s" %
                      (w, WNAME.get(w, "?"), A[w], B[w], raw, "✅0" if raw == 0 else "⚠️非0"))
    # NIC
    print("NIC 口径 (pre2 -> post2):")
    A, ca = nic(txt, "pre2")
    B, cb = nic(txt, "post2")
    tA, tB = phase_ts(txt, "nic_pre2"), phase_ts(txt, "nic_post2")
    if A and B:
        dt = tB - tA
        print("   COALESCE(pre2)=%s" % ca)
        print("   COALESCE(post2)=%s" % cb)
        print("   Δt(nic_pre2->nic_post2) = %.3f s" % dt)
        for k in sorted(set(A) & set(B)):
            d = B[k] - A[k]
            flag = ""
            if k == "port_rx_packets":
                flag = " ⇒ %.1f fps" % (d / dt)
            if k == "port_rx_good_bytes":
                flag = " ⇒ %.4f Gbps (线上字节, 含开销)" % (d * 8 / dt / 1e9)
            if k == "rx-2.rx_packets":
                flag = " ⇒ %.1f fps (交付到 DMA 环)" % (d / dt)
            print("   %-24s %14d -> %14d  Δ=%d%s" % (k, A[k], B[k], d, flag))
        bp = B["port_rx_good_bytes"] - A["port_rx_good_bytes"]
        pp = B["port_rx_packets"] - A["port_rx_packets"]
        if pp:
            print("   Δbytes/Δpackets = %.4f" % (bp / pp))
    # 逐秒 NIC 队列轨迹
    q = []
    for m in re.finditer(r"TRACE_RC (\d+) (\d+) ([\d.]+) NICQ (.*)", txt):
        i = int(m.group(1))
        d = dict(re.findall(r"([\w.\-]+)=(\d+)", m.group(4)))
        q.append((i, m.group(4)))
    if q:
        print("逐点 NICQ (前后各 3 + 中间 1):")
        for idx in list(range(3)) + [len(q) // 2] + list(range(len(q) - 3, len(q))):
            if 0 <= idx < len(q):
                print("   i=%d %s" % (q[idx][0], q[idx][1]))
    # 相位
    for name in ("ctrl0_ping_nocflood", "ping_while_flood", "ping_after_stop", "content"):
        m = re.search(r"### PHASE %s[^\n]*\n(.*?)(?=\n### PHASE|\n### LR_DONE)" % name, txt, re.S)
        if m:
            blk = m.group(1)
            keep = [l for l in blk.splitlines() if re.search(r"ping statistics|received|rtt|_NC_RC|TCPDUMP_RC|packets captured|dropped by kernel|CONTENT_PCAP", l)]
            print("PHASE %-22s: %s" % (name, " | ".join(keep)))
    print("BOARD_END BID=%s 0x08=%s" % (
        re.search(r"LR_META_BOARD_BID_END=(\S+)", txt).group(1) if re.search(r"LR_META_BOARD_BID_END=(\S+)", txt) else "?",
        re.search(r"LR_META_BOARD_0x08_END=(\S+)", txt).group(1) if re.search(r"LR_META_BOARD_0x08_END=(\S+)", txt) else "?"))


for p in sys.argv[1:]:
    report(p)
