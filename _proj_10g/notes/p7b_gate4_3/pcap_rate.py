"""pcap_rate.py — 只用 pcap **时间戳** 独立反解帧率 (F4 的独立口径, closeout §4)。

为什么它独立: 抓包点在**驱动队列** (不是 socket), 与"板侧 RTL 计数""激励工具的 socket"
是三条不同的消费者路径; 而且**逐帧时间戳**, 没有 NIC 计数那种 ~1 s 的刷新量子。

判据口径: fps = (末帧时刻 − 首帧时刻) / (帧数 − 1)   —— **端点口径**, 不含抓包进程的启停时间。
⚠️ 该读数是**下界** (pcap 自己丢帧会低估), 且窗口只有 ~28 ms —— 它可用是因为板侧速率是硬件常数。
⚠️ 必须按 pcap 内部时间戳算; 用 `date +%s.%N` 的墙钟会把 tcpdump 的启停 (~60 ms) 算进去 (假低 ~3×)。
"""
import hashlib
import struct
import sys
import collections

BOARD = '192.168.100.2'


def read_pcap(path):
    d = open(path, 'rb').read()
    mg = struct.unpack('<I', d[:4])[0]
    if mg == 0xA1B2C3D4:
        us = True
    elif mg == 0xA1B23C4D:
        us = False
    else:
        raise SystemExit('not LE pcap: %08x' % mg)
    p, out = 24, []
    while p + 16 <= len(d):
        ts, sub, cl, wl = struct.unpack('<IIII', d[p:p + 16])
        p += 16
        out.append((ts + sub / (1e6 if us else 1e9), d[p:p + cl]))
        p += cl
    return out


def main():
    pkts = read_pcap(sys.argv[1])
    sel = []
    for ts, pkt in pkts:
        if len(pkt) < 42 or struct.unpack('!H', pkt[12:14])[0] != 0x0800:
            continue
        ihl = (pkt[14] & 0xF) * 4
        if '.'.join(str(b) for b in pkt[26:30]) != BOARD:
            continue
        u = 14 + ihl
        if struct.unpack('!H', pkt[u + 2:u + 4])[0] != 8081:
            continue
        plen = struct.unpack('!H', pkt[u + 4:u + 6])[0] - 8      # UDP 长度 - 8 = 载荷长
        sel.append((ts, plen, pkt[u + 8:]))
    if len(sel) < 2:
        print('  [SKIP] 板子->:8081 的帧 <2 (n=%d) ⇒ 反解不出帧率' % len(sel))
        return 1
    lens = collections.Counter(l for _, l, _ in sel)
    dt = sel[-1][0] - sel[0][0]
    n = len(sel)
    # ⚠️ 时间戳是**批量打戳**的 (同一 µs 值会挂 2~8 个**内容不同**的帧) ⇒ **帧间隔分布不可用**;
    #    端点跨度 (首末时刻) 不受影响。先证明"记录数 = 不同载荷数" ⇒ 没有重复副本 (否则要除副本因子)。
    uniq = len(set(hashlib.md5(p).hexdigest() for _, _, p in sel))
    ts_uniq = len(set(sel_i[0] for sel_i in sel))
    wire = sum(l + 42 for _, l, _ in sel)      # 14(eth) + 20(ip) + 8(udp)
    print('  pcap=%s' % sys.argv[1])
    print('  板子->本机:8081 帧 = %d ; UDP 载荷长度分布 = %s' % (n, dict(lens)))
    print('  去重自证: 不同载荷 = %d / 记录数 = %d ⇒ 重复副本 = %d (非 0 就说明抓包点自带了副本, 必须除掉)'
          % (uniq, n, n - uniq))
    print('  时间戳: 首=%.6f 末=%.6f  Δ=%.9f s ; 不同时间戳 = %d (⇒ 批量打戳桶 ≈ %.1f µs)'
          % (sel[0][0], sel[-1][0], dt, ts_uniq, dt / max(ts_uniq - 1, 1) * 1e6))
    print('  ⇒ **端点口径** fps = (n-1)/Δ = %.0f fps   (下界: pcap 丢帧会低估; 桶粒度给 ±%.2f%% 不确定)'
          % ((n - 1) / dt, 100.0 * (dt / max(ts_uniq - 1, 1)) / dt))
    print('  ⇒ 线上字节率 = %.2f Mbps (IP 总长 + 14 B 以太头, 含 FCS/不含 IFG 前导)'
          % (wire * 8 / dt / 1e6))
    print('  ⚠️ 帧间隔分布**不打印**: 批量打戳会让它退化成 0/桶宽的伪双峰 (与真帧率无关)')
    return 0


sys.exit(main())
