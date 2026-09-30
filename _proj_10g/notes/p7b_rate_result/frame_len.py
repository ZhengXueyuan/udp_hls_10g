#!/usr/bin/env python3
"""frame_len.py -- 从 pcap 逐帧读出**真实线长**与 IP/UDP 长度字段 (在 pcap 里直接解)。

为什么必须做: 速率判据的"每帧多少字节"是口径的**分母**。P7B_RATE_MEASURE_PLAN.md §2.2 写的是
1472 载荷 / 1518 线长 / 193.24 拍, 但板上实测拍/帧 = 192.00、对端 NIC 报平均帧长 1510.00
⇒ **两者至少有一个是错的**。本脚本用线上一手帧长把口径钉死 (不作任何假设)。
用法: frame_len.py <pcap> [max_frames]
"""
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def frames(path):
    d = open(path, "rb").read()
    magic = struct.unpack("<I", d[:4])[0]
    if magic == 0xA1B2C3D4:
        end, nano = "<", False
    elif magic == 0xD4C3B2A1:
        end, nano = ">", False
    elif magic == 0xA1B23C4D:
        end, nano = "<", True
    else:
        raise SystemExit("不是 pcap (magic=%08x)" % magic)
    off = 24
    while off + 16 <= len(d):
        ts, tus, ln, orig = struct.unpack(end + "IIII", d[off:off + 16])
        off += 16
        yield ts, tus, d[off:off + ln]
        off += ln


def main():
    path = sys.argv[1]
    mx = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    n = 0
    lens, iptot, udplen, pays = [], [], [], []
    for ts, tus, f in frames(path):
        n += 1
        if len(f) < 42:
            print("frame %d: 过短 %d B" % (n, len(f)))
            continue
        eth_len = len(f)                      # pcap 记录长 = 线上帧长(不含前导/IFG, 含 FCS)
        ip_tot = struct.unpack(">H", f[16:18])[0]
        u = 14 + 20                            # 无 IP option 时 UDP 头起点
        udp_len = struct.unpack(">H", f[u + 4:u + 6])[0]
        pay = udp_len - 8
        lens.append(eth_len)
        iptot.append(ip_tot)
        udplen.append(udp_len)
        pays.append(pay)
        if n <= 6:
            print("frame %d: eth_len=%d ip_tot=%d udp_len=%d payload=%d  (ip_tot+14=%d)"
                  % (n, eth_len, ip_tot, udp_len, pay, ip_tot + 14))
        if n >= mx:
            break
    if not lens:
        raise SystemExit("一帧都没解析到")
    print("---- 汇总 (n=%d) ----" % n)
    print("eth_len 集合 = %s" % sorted(set(lens)))
    print("ip_tot  集合 = %s" % sorted(set(iptot)))
    print("udp_len 集合 = %s" % sorted(set(udplen)))
    print("payload 集合 = %s" % sorted(set(pays)))
    print("ip_tot+14 == eth_len-4 ? %s" % all(t + 14 == e - 4 for t, e in zip(iptot, lens)))
    print("udp_len+14+20-4 == eth_len ? %s" % all(u + 34 - 4 == e for u, e in zip(udplen, lens)))


if __name__ == "__main__":
    main()
