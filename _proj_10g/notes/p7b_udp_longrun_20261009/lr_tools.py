#!/usr/bin/env python3
"""lr_tools.py -- P7b UDP 长流轮的三件本机工具 (2026-10-09)

  synth   <out.pcap> [--n 8] [--off 12345678] [--flip K:BYTE] [--gap K] [--fcs]
          造一个**合成 pcap**: 载荷 = 参考图案流 offset 处的连续片段 (逐字节),
          用来在**上板之前**自检 p7b_udp_content_check 能不能找到偏移/能不能抓出翻位。
  analyze <log.txt>
          解析 udp_longrun.sh 的 stdout: 逐点速率 + 全窗合计 + 七项读数 + 回卷自证。
  pcapgeom <pcap>
          抓包几何 + IP/UDP 校验和逐帧复核 (板外独立口径)。
"""
import re
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1


def xs(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def stream_at(off, n):
    s = SEED
    for _ in range(off):
        s = xs(s)
    out = bytearray()
    for _ in range(n):
        out.append((s >> 24) & 0xFF)
        s = xs(s)
    return bytes(out)


# ----------------------------------------------------------------------------- synth
def cmd_synth(argv):
    out = argv[0]
    n, off, flip, gap, fcs = 8, 0, None, None, False
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--n":
            n = int(argv[i + 1]); i += 2
        elif a == "--off":
            off = int(argv[i + 1]); i += 2
        elif a == "--flip":
            k, b = argv[i + 1].split(":"); flip = (int(k), int(b)); i += 2
        elif a == "--gap":
            gap = int(argv[i + 1]); i += 2
        elif a == "--fcs":
            fcs = True; i += 1
        else:
            raise SystemExit("unknown " + a)
    paylen = 1472
    pkts = []
    cur = off
    for k in range(n):
        payload = bytearray(stream_at(cur, paylen))
        if flip and flip[0] == k:
            payload[flip[1]] ^= 0xFF
        cur += paylen
        if gap and gap == k:
            cur += 3 * paylen          # 模拟抓包丢 3 帧 (流水里有洞)
        eth = bytearray(14)
        eth[0:6] = bytes.fromhex("000f532c6801")
        eth[6:12] = bytes.fromhex("000a3501fec0")
        eth[12:14] = b"\x08\x00"
        ip = bytearray(20)
        ip[0] = 0x45
        iptot = 20 + 8 + paylen
        struct.pack_into(">H", ip, 2, iptot)
        ip[8] = 64
        ip[9] = 17
        ip[12:16] = bytes([192, 168, 100, 2])
        ip[16:20] = bytes([192, 168, 100, 100])
        struct.pack_into(">H", ip, 10, csum16(bytes(ip)))
        udp = bytearray(8)
        struct.pack_into(">HHH", udp, 0, 8081, 8081, 8 + paylen)
        ph = ip[12:20] + b"\x00\x11" + struct.pack(">H", 8 + paylen)
        u = csum16(ph + bytes(udp) + bytes(payload))
        struct.pack_into(">H", udp, 6, u if u else 0xFFFF)
        frame = bytes(eth) + bytes(ip) + bytes(udp) + bytes(payload)
        if fcs:
            frame += b"\x00\x00\x00\x00"
        pkts.append(frame)
    with open(out, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1))
        ts = 1000
        for p in pkts:
            f.write(struct.pack("<IIII", ts, 0, len(p), len(p)))
            f.write(p)
            ts += 1
    print("SYNTH_OK %s frames=%d off=%d flip=%s gap=%s fcs=%s paylen=%d" % (out, n, off, flip, gap, fcs, paylen))


def csum16(b):
    if len(b) % 2:
        b = b + b"\x00"
    s = 0
    for i in range(0, len(b), 2):
        s += (b[i] << 8) | b[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


# ---------------------------------------------------------------------------- analyze
WNAME = {5: "gmii_free_FE", 9: "udpapp_tx_bytes", 20: "mac_tx_frames", 43: "mtx_tx_words",
         56: "udpapp_tx_ovf", 21: "tx_stat_abort", 11: "udpapp_rx_bytes", 13: "udpapp_mismatch",
         52: "app_tx_frames", 41: "mtx_flush_words", 42: "mtx_flush_done", 59: "stx_fifo_ovf",
         60: "srx_fifo_ovf", 44: "?", 62: "rx_occ_bytes", 61: "stat_wu"}


def parse_snaps(txt):
    snaps = []
    cur = None
    for line in txt.splitlines():
        m = re.match(r"^SNAP_BEGIN (\S+) gen=(\d+)", line)
        if m:
            cur = {"tag": m.group(1), "gen": int(m.group(2)), "w": {}}
            snaps.append(cur)
            continue
        m = re.match(r"^SNAP_END", line)
        if m:
            cur = None
            continue
        m = re.match(r"^W(\d+)\s+\S+\s+(\S+)\s+(0x[0-9a-fA-F]+)", line)
        if m and cur is not None:
            cur["w"][int(m.group(1))] = int(m.group(3), 16)
    return snaps


def cmd_analyze(argv):
    path = argv[0]
    txt = open(path, encoding="utf-8", errors="replace").read()
    print("=== FILE %s ===" % path)
    for pat in ("LR_META_TAG", "LR_META_SECS", "LR_META_SCRIPT_MD5", "LR_META_SNAP_MD5",
                "LR_META_UDP_SRC_MD5", "LR_META_BOARD_BID_PRE", "LR_META_BIT_SHA",
                "ID_MAGIC", "ID_BID", "ID_MARKER", "ID_UNIMPL", "LR_META_IF",
                "LR_META_BOARD_BID_END"):
        for m in re.finditer(r"^%s.*$" % pat, txt, re.M):
            print("  " + m.group(0))
    # NIC 块
    nic = {}
    for tag in ("pre", "pre2", "post", "post2"):
        m = re.search(r"### PHASE nic_%s[^\n]*\n(.*?)(?=\n###|\n### PHASE)" % tag, txt, re.S)
        if not m:
            continue
        blk = m.group(1)
        vals = {}
        for k in ("port_rx_good_bytes", "port_rx_packets", "port_rx_bad", "rx_eth_crc_err",
                  "port_rx_nodesc_drops", "port_rx_overflow", "port_rx_bytes", "port_rx_1024_to_15xx",
                  "port_rx_15xx_to_jumbo", "port_tx_packets", "port_tx_bytes",
                  "rx_ip_hdr_chksum_err", "rx_tcp_udp_chksum_err", "rx_frm_trunc", "rx_overlength",
                  "rx-0.rx_packets", "rx-1.rx_packets", "rx-2.rx_packets", "rx-3.rx_packets",
                  "UdpInDatagrams", "UdpNoPorts", "UdpInErrors", "UdpRcvbufErrors",
                  "IcmpOutDestUnreachs", "IpInReceives", "IpOutRequests",
                  "TcpInSegs", "TcpOutSegs", "TcpRetransSegs"):
            mm = re.search(r"^\s*%s:\s*(\d+)" % re.escape(k), blk, re.M)
            if mm:
                vals[k] = int(mm.group(1))
        cm = re.search(r"### COALESCE (.*)", blk)
        nic[tag] = (vals, cm.group(1) if cm else "?")
    for tag, (v, c) in nic.items():
        print("NIC_%s COALESCE=%s" % (tag, c))
        print("   " + " ".join("%s=%d" % (k, v[k]) for k in sorted(v)))
    # trace 点
    snaps = parse_snaps(txt)
    pts = [s for s in snaps if re.match(r"^.*_s\d+$", s["tag"])]
    pts.sort(key=lambda s: int(s["tag"].split("_s")[-1]))
    print("TRACE_POINTS n=%d first=%s gen=%d last=%s gen=%d" % (len(pts), pts[0]["tag"], pts[0]["gen"], pts[-1]["tag"], pts[-1]["gen"]) if pts else "TRACE_POINTS n=0")
    # gen 自证
    gens = [s["gen"] for s in pts]
    badg = [i for i in range(1, len(gens)) if (gens[i] - gens[i - 1]) % 65536 != 1]
    print("GEN_WITNESS step1_all=%s bad_at=%s" % (not badg, badg[:10]))
    # 逐点
    rows = []
    for i in range(len(pts) - 1):
        a, b = pts[i]["w"], pts[i + 1]["w"]
        if 5 not in a or 5 not in b or 9 not in a:
            continue
        dc = (b[5] - a[5]) % (1 << 32)
        db = (b[9] - a[9]) % (1 << 32)
        df = (b[20] - a[20]) % (1 << 32)
        dw = (b[43] - a[43]) % (1 << 32)
        dt = dc / 156.25e6
        rate = db * 8 / dt / 1e9
        fps = df / dt
        p = dw / df if df else 0
        expect_bytes = 1472 * df
        wrap_flag = "" if abs(db - expect_bytes) <= 1472 * 4 else " ⚠️BYTE_FRAME_MISMATCH"
        rows.append((i, dt, db, df, rate, fps, p, wrap_flag))
    if rows:
        rates = [r[4] for r in rows]
        print("TRACE_RATE payload_Gbps: min=%.4f max=%.4f mean=%.4f median=%.4f n=%d" %
              (min(rates), max(rates), sum(rates) / len(rates), sorted(rates)[len(rates) // 2], len(rates)))
        print("TRACE_FPS: min=%.1f max=%.1f mean=%.1f" % (min(r[5] for r in rows), max(r[5] for r in rows), sum(r[5] for r in rows) / len(rows)))
        print("TRACE_P_words_per_frame: min=%.5f max=%.5f mean=%.5f" % (min(r[6] for r in rows), max(r[6] for r in rows), sum(r[6] for r in rows) / len(rows)))
        print("TRACE_dt_s: min=%.4f max=%.4f sum=%.4f" % (min(r[1] for r in rows), max(r[1] for r in rows), sum(r[1] for r in rows)))
        print("--- per-second (第 i 段 = 点 i -> i+1) ---")
        for r in rows:
            print("  seg %3d dt=%.4f ΔW9=%12d ΔW20=%9d payload=%8.4f Gbps fps=%10.1f P=%9.4f%s" %
                  (r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]))
        tot_dt = sum(r[1] for r in rows)
        tot_b = sum(r[2] for r in rows)
        tot_f = sum(r[3] for r in rows)
        print("WHOLE_WINDOW(sum of segments) points=%d..%d dt=%.4f s bytes=%d frames=%d payload=%.4f Gbps fps=%.1f P=%.5f" %
              (0, len(pts) - 1, tot_dt, tot_b, tot_f, tot_b * 8 / tot_dt / 1e9, tot_f / tot_dt, sum(r[2] for r in rows) and (sum(r[6] * r[3] for r in rows) / tot_f) if tot_f else 0))
        # 全窗差分 (raw, mod 2^32, 回卷 k 由帧数反推)
        A, B = pts[0]["w"], pts[-1]["w"]
        dfA = (B[20] - A[20]) % (1 << 32)
        dbA = (B[9] - A[9]) % (1 << 32)
        exp = 1472 * dfA
        k = round((exp - dbA) / (1 << 32))
        print("WHOLE_WINDOW(raw diff) ΔW20=%d ΔW9_raw=%d 期望字节=%d ⇒ 回卷 k=%d (还原=%d, 残差=%d)" %
              (dfA, dbA, exp, k, dbA + k * (1 << 32), dbA + k * (1 << 32) - exp))
        dcA = (B[5] - A[5]) % (1 << 32)
        print("WHOLE_WINDOW(raw diff) ΔW5_raw=%d ⇒ 时基回卷 k≥%d (由外部墙钟/帧数定, 见下)" %
              (dcA, int(tot_dt * 156.25e6 // (1 << 32))))
        for w in (43, 56, 21, 11, 13):
            if w in A and w in B:
                raw = (B[w] - A[w]) % (1 << 32)
                neg = B[w] < A[w]
                print("WHOLE_WINDOW(raw diff) W%-3d %-18s raw=%d (B<A=%s)" % (w, WNAME.get(w, "?"), raw, neg))
    # 关键块原文
    for pat in ("flood_check", "content", "ping_while_flood", "ping_after_stop", "ctrl0_ping_nocflood"):
        m = re.search(r"### PHASE %s(.*?)(?=\n### PHASE|\n### LR_DONE)" % pat, txt, re.S)
        if m:
            print("=== PHASE %s ===" % pat)
            print(m.group(1).strip()[:2500])


# --------------------------------------------------------------------------- pcapgeom
def cmd_pcapgeom(argv):
    path = argv[0]
    d = open(path, "rb").read()
    magic = struct.unpack("<I", d[:4])[0]
    end = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
    off = 24
    n = 0
    lens, pays, ips, udps = [], [], [], []
    ipbad = udpbad = short = 0
    firstts = lastts = None
    while off + 16 <= len(d):
        ts, tus, ln, orig = struct.unpack(end + "IIII", d[off:off + 16])
        off += 16
        f = d[off:off + ln]
        off += ln
        n += 1
        if firstts is None:
            firstts = ts + tus / 1e6
        lastts = ts + tus / 1e6
        if len(f) < 42:
            short += 1
            continue
        lens.append(len(f))
        ip = f[14:34]
        ipc = csum16(ip)
        if ipc != 0:
            ipbad += 1
        udp = f[34:42]
        udplen = struct.unpack(">H", udp[4:6])[0]
        pl = udplen - 8
        pays.append(pl)
        ips.append(struct.unpack(">H", f[16:18])[0])
        udps.append(udplen)
        ph = ip[12:16] + ip[16:20] + b"\x00\x11" + struct.pack(">H", udplen)
        u = csum16(ph + udp + f[42:42 + pl])
        if u != 0:
            udpbad += 1
    print("PCAP n=%d ethlen=%s iplen=%s udplen=%s payload=%s" % (n, sorted(set(lens)), sorted(set(ips)), sorted(set(udps)), sorted(set(pays))))
    print("PCAP ip_csum_bad=%d udp_csum_bad=%d short=%d" % (ipbad, udpbad, short))
    if firstts is not None:
        print("PCAP span_s=%.6f (%.1f frames/s 视采样)" % (lastts - firstts, n / max(lastts - firstts, 1e-9)))
    # 帧间空隙: pcap 里连续帧的 ts 差 (同一条流上未被丢弃时应该 ≈ 1.54 µs)
    print("PCAP 结论: 几何 + 校验和独立复核完成")


def main():
    cmd = sys.argv[1]
    if cmd == "synth":
        cmd_synth(sys.argv[2:])
    elif cmd == "analyze":
        cmd_analyze(sys.argv[2:])
    elif cmd == "pcapgeom":
        cmd_pcapgeom(sys.argv[2:])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
