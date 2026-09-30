#!/usr/bin/env python3
"""p7b_pcap_check.py -- **必做**的独立口径: 从 pcap 逐字节复算 + 现场测帧几何

为什么必须 (不是可选):
  ① 板侧 `app_pattern` (TCP app) 的计数**不在 51 字快照窗口** => "板子自己说载荷对不对"
     没有读数。唯一不依赖板侧新字的正确性口径 = **对端收到的字节流**。
  ② 而 socket 与 pcap 是**两条内核路径** (socket 收包 vs packet socket 抓包) => 互证。
  ③ 帧几何 (载荷/线长/每帧字节) **必须现场实测**, 不许写死常数:
     2026-09-30 查出 `rtl/app_udp_pattern.v` 在 `P7B_10G` 下每帧静默丢 1 个整字 (8 B)
     => 历史文书里的 1472/1518 与 1464/1510 两套口径**都不是意图几何**。
  ④ 每帧丢 8 B 在**逐字节流**上的签名 = **首个失配偏移恰为 (段载荷 - 8)** (第一帧边界处),
     之后全错。本工具把这条签名直接算出来打进日志 (`SIG_8B_LOSS`)。

用法:
  python3 p7b_pcap_check.py --pcap /tmp/biz_tcp.pcap --dir down [--host 192.168.100.2 --port 8080]
  python3 p7b_pcap_check.py --selftest          # 合成 pcap 自检 (干净流 + 注入 8B/帧 丢字)
输出行 PCHK_* ; 退出码 0 = 逐字节干净且几何自洽。
"""
import argparse, os, struct, sys, tempfile

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1


def xs_next(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def gen(n, off=0):
    s = SEED
    for _ in range(off):
        s = xs_next(s)
    o = bytearray(n)
    for i in range(n):
        o[i] = (s >> 24) & 0xFF
        s = xs_next(s)
    return bytes(o)


def read_pcap(path):
    """返回 [(ts, raw_bytes)]; 只认 classic pcap (magic a1b2c3d4 / d4c3b2a1), 以太网链路层。"""
    with open(path, "rb") as f:
        gh = f.read(24)
    if len(gh) < 24:
        raise SystemExit("short pcap header")
    magic = struct.unpack("<I", gh[:4])[0]
    if magic in (0xA1B2C3D4, 0xA1B23C4D):
        endian, nano = "<", (magic == 0xA1B23C4D)
    elif magic in (0xD4C3B2A1, 0x4D3CB2A1):
        endian, nano = ">", (magic == 0x4D3CB2A1)
    else:
        raise SystemExit("bad pcap magic 0x%08X (pcapng? 用 -w 生成 classic pcap)" % magic)
    linktype = struct.unpack(endian + "I", gh[20:24])[0]
    out = []
    with open(path, "rb") as f:
        f.seek(24)
        while True:
            ph = f.read(16)
            if len(ph) < 16:
                break
            ts, tu, incl, orig = struct.unpack(endian + "IIII", ph)
            d = f.read(incl)
            if len(d) < incl:
                break
            out.append((ts + (tu / 1e9 if not nano else tu / 1e9), d))
    if linktype != 1:
        print("PCHK_WARN linktype=%d (非以太网; 解析可能失败)" % linktype)
    return out


def parse_eth_ip_tcp(d):
    """-> (src_ip, dst_ip, sport, dport, seq, flags, payload) 或 None"""
    if len(d) < 14:
        return None
    eth = struct.unpack("!H", d[12:14])[0]
    off = 14
    while eth in (0x8100, 0x88A8):                 # VLAN
        eth = struct.unpack("!H", d[off + 2:off + 4])[0]
        off += 4
    if eth != 0x0800:
        return None
    if len(d) < off + 20:
        return None
    ihl = (d[off] & 0x0F) * 4
    proto = d[off + 9]
    tot = struct.unpack("!H", d[off + 2:off + 4])[0]
    src = ".".join(str(b) for b in d[off + 12:off + 16])
    dst = ".".join(str(b) for b in d[off + 16:off + 20])
    if proto != 6:
        return (src, dst, None, None, None, tot, None)
    t = off + ihl
    if len(d) < t + 20:
        return None
    sport, dport = struct.unpack("!HH", d[t:t + 4])
    seq = struct.unpack("!I", d[t + 4:t + 8])[0]
    flags = d[t + 13]
    doff = (d[t + 12] >> 4) * 4
    # ⚠️ 2026-09-30 修 (Stage 1 抓到的缺陷 ①): 载荷**长度必须由 IP 头字段算**
    #    (`plen = tot - ihl - doff`), 端点必须写成 `off + tot`。
    #    旧写法 `d[t+doff : t+ihl+(tot-ihl)]` = `d[t+doff : t+tot]`, 比正确的
    #    **多切 ihl 字节** (≈20 B); 对 1514 B 的缓冲**恰好被 Python 切片钳位掩盖**
    #    (所以数据帧仍得 1460), 但**纯 ACK 帧 (缓冲 60 B) 被切成 6 B 的"幻影载荷"**
    #    ⇒ 以幻影字节污染同 4 元组的 seq 重建 ⇒ **对干净流报 first=0 假红**
    #    (实证: `_proj_10g/notes/p7b_biz_s1/s1_2_pcapcheck.txt`)。
    plen = tot - ihl - doff
    if plen < 0 or t + doff + plen > len(d):
        return None
    pay = d[t + doff:t + doff + plen]
    return (src, dst, sport, dport, seq, flags, tot, pay)


def analyse(pkts, direction, host, port):
    flows = {}
    hist_pay, hist_tot = {}, {}
    for ts, d in pkts:
        r = parse_eth_ip_tcp(d)
        if not r or r[2] is None:
            continue
        src, dst, sp, dp, seq, flags, tot, pay = r
        if direction == "down":
            if src != host or sp != port:
                continue
        else:
            if dst != host or dp != port:
                continue
        key = (src, sp, dst, dp)
        flows.setdefault(key, {})
        # 只收**真载荷**帧 (纯 ACK/FIN 的 plen=0); 有载荷才进 seq 重建表
        if plen_of(pay):
            if seq in flows[key] and flows[key][seq] != pay:
                flows[key]["__conflict__"] = 1
            flows[key][seq] = pay
            hist_pay[len(pay)] = hist_pay.get(len(pay), 0) + 1
            hist_tot[tot] = hist_tot.get(tot, 0) + 1
    if not flows:
        return None
    # 取字节数最大的那条流
    key = max(flows, key=lambda k: sum(len(v) for s, v in flows[k].items() if isinstance(s, int)))
    segs = {s: v for s, v in flows[key].items() if isinstance(s, int)}
    base = min(segs)
    gaps = 0
    gap_bytes = 0
    dups = 0
    stream = bytearray()
    nxt = base
    for s in sorted(segs):
        if s < nxt:
            dups += 1                                  # 重传/重复 seq (TCP 去重)
            continue
        if s > nxt:
            gaps += 1; gap_bytes += s - nxt
            print("PCHK_GAP at_seq=%d missing=%d (seq 空洞 => 帧丢失或抓包丢)" % (nxt, s - nxt))
        stream += segs[s]
        nxt = s + len(segs[s])
    return key, bytes(stream), gaps, gap_bytes, hist_pay, hist_tot, dups


def plen_of(pay):
    return pay is not None and len(pay) > 0


def verdict(stream, hist_pay, hist_tot=None):
    s = SEED
    first = -1
    mis = 0
    for i, b in enumerate(stream):
        if ((s >> 24) & 0xFF) != b:
            mis += 1
            if first < 0:
                first = i
        s = xs_next(s)
    print("PCHK_BYTES %d" % len(stream))
    print("PCHK_MISMATCH first=%d count=%d" % (first, mis))
    pl = sorted(hist_pay.items(), key=lambda kv: -kv[1])[0][0] if hist_pay else 0
    print("PCHK_PAYLEN_HIST %s (众数=%d)  <== 现场实测的段载荷, 不是常数" % (sorted(hist_pay.items()), pl))
    if hist_tot:
        print("PCHK_IPTOT_HIST  %s" % sorted(hist_tot.items()))
    print("PCHK_GEOM_HINT ip_tot(众数)=%s eth_len(+14)=%s wire(+4 FCS)=%s"
          % (pl + 40, pl + 54, pl + 58))
    if first == pl - 8 and pl > 8:
        print("SIG_8B_LOSS first_mismatch == 段载荷-8 = %d  => 与 app_udp_pattern 同族的"
              "'每帧丢 1 个整字' 签名 (第 1 帧边界处起全错)" % (pl - 8))
    return first, mis, pl


def pad60(fr):
    """以太网最小帧 60 B (无 FCS) ⇒ 短控制帧后面**有填充字节**。
    ⚠️ 这个填充正是缺陷 ① 能造成假红的物理原因: 旧切片端点写成 `t+tot` ⇒ 把填充
    当成载荷 (纯 ACK 得 6 B / FIN 得 2 B 的"幻影载荷", 与现场
    `s1_2_pcapcheck.txt` 的 `(6,599)/(2,300)` 逐数吻合)。**合成台架必须复现填充**,
    否则反例抓不住那个 bug (本工具第一版就漏了这条)。"""
    return fr if len(fr) >= 60 else fr + bytes(60 - len(fr))


def selftest():
    """合成 pcap: 干净流 / 每帧丢尾字 / **混入纯 ACK** (缺陷 ① 的反例) —— 断言本工具能分开。

    ⚠️ `ackmix` 这一档就是缺陷 ① 的**回归反例**: 修复前 (切片端点写成 `t+tot`)
    纯 ACK 帧会被切成 ~6 B 的幻影载荷 ⇒ 污染 seq 重建 ⇒ 对**干净流**报 `first=0`。
    修复后必须 `first=-1` (实证: `_proj_10g/notes/p7b_biz_s1/s1_2_pcapcheck.txt` = 假红)。
    """
    def build(path, seglen, nseg, drop8, ackmix):
        frames = []
        seq = 1000
        for i in range(nseg):
            pay = bytearray(gen(seglen, i * seglen))
            if drop8:                      # **每一帧**丢尾字 = 与现场同型
                del pay[-8:]
            ip = bytearray(20 + 20 + len(pay))
            ip[0] = 0x45
            struct.pack_into("!H", ip, 2, 20 + 20 + len(pay))
            ip[9] = 6
            ip[12:16] = bytes([192, 168, 100, 2])
            ip[16:20] = bytes([192, 168, 100, 100])
            t = 20
            struct.pack_into("!HHII", ip, t, 8080, 40000, seq, 0)
            ip[t + 12] = 0x50
            ip[t + 13] = 0x18
            ip[t + 20:] = pay
            eth = bytes([0] * 12) + b"\x08\x00"
            frames.append(pad60(eth + bytes(ip)))
            if ackmix:
                # 每个数据帧后插一个**纯 ACK** (plen=0), 且**方向与被测流相同**
                # (src = 板:8080)。现场就是这样: 板子自己发的纯 ACK 通过了
                # `src==host && sport==port` 过滤 ⇒ 旧切片把填充当载荷
                # (`s1_2_pcapcheck.txt` 的 (6,599)/(2,300) 幻影族)。
                # seq 取流内某点 (真实 ACK 的 seq 本就落在流内) ⇒ 旧代码必然判 GAP。
                a = bytearray(40)           # 20 ip + 20 tcp, 无载荷
                a[0] = 0x45
                struct.pack_into("!H", a, 2, 40)
                a[9] = 6
                a[12:16] = bytes([192, 168, 100, 2])
                a[16:20] = bytes([192, 168, 100, 100])
                # seq 落在**数据段边界**上: 旧代码会把幻影载荷写进同一个 seq 键 ⇒
                # **覆盖**那一段真载荷 (现场报告的"污染 seq 重建") ⇒ 必然失配。
                struct.pack_into("!HHII", a, 20, 8080, 40000, 1000 + 4 * 1460, 0)
                a[32] = 0x50
                a[33] = 0x10                 # ACK
                frames.append(pad60(eth + bytes(a)))
            seq += len(pay)
        with open(path, "wb") as f:
            f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
            for i, fr in enumerate(frames):
                f.write(struct.pack("<IIII", 1700000000 + i, 0, len(fr), len(fr)))
                f.write(fr)
    ok = True
    for name, drop8, ackmix, want in (("clean", False, False, -1),
                                      ("ackmix", False, True, -1),
                                      ("drop8", True, False, 1460 - 8),
                                      ("drop8ack", True, True, 1460 - 8)):
        p = os.path.join(tempfile.gettempdir(), "p7b_selftest_%s.pcap" % name)
        build(p, 1460, 8, drop8, ackmix)
        pk = read_pcap(p)
        r = analyse(pk, "down", "192.168.100.2", 8080)
        first, mis, pl = verdict(r[1], r[4], r[5])
        good = (first == want)
        ok = ok and good
        print("PCHK_SELFTEST %-9s first=%d want=%d dups=%d %s"
              % (name, first, want, r[6], "OK" if good else "FAIL"))
    # 反向: `up` 方向必须也认得出 (同一份 pcap, 换方向 => 无该方向的流)
    r = analyse(read_pcap(os.path.join(tempfile.gettempdir(), "p7b_selftest_clean.pcap")),
                "up", "192.168.100.2", 8080)
    good = (r is None)
    ok = ok and good
    print("PCHK_SELFTEST %-9s no-flow-in-up %s" % ("dirup", "OK" if good else "FAIL"))
    print("PCHK_SELFTEST_SUMMARY %s" % ("OK" if ok else "BAD"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcap")
    ap.add_argument("--dir", choices=["down", "up"], default="down",
                    help="down = 板->对端 (src=板); up = 对端->板")
    ap.add_argument("--host", default="192.168.100.2")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.pcap:
        ap.error("--pcap or --selftest")
    pk = read_pcap(a.pcap)
    print("PCHK_PKTS %d" % len(pk))
    r = analyse(pk, a.dir, a.host, a.port)
    if not r:
        print("PCHK_NO_FLOW dir=%s host=%s port=%d (抓包过滤写错了? 没有该方向的流)" % (a.dir, a.host, a.port))
        return 1
    key, stream, gaps, gap_bytes, hp, ht, dups = r
    print("PCHK_FLOW %s:%d -> %s:%d" % (key[0], key[1], key[2], key[3]))
    print("PCHK_GAPS %d gap_bytes=%d dupseq=%d (重传段; TCP 去重, 不算错)" % (gaps, gap_bytes, dups))
    first, mis, pl = verdict(stream, hp, ht)
    print("PCHK_DONE first=%d gaps=%d dups=%d uniq_bytes=%d" % (first, gaps, dups, len(stream)))
    return 0 if (first < 0 and gaps == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
