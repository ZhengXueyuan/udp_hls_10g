#!/usr/bin/env python3
"""parse_pcap_tcp.py -- 裸 pcap 读取器: 直接打 TCP 头的**原始字段**, 不经 tcpdump 显示层.

用法: python3 parse_pcap_tcp.py <file.pcap>
为什么需要它: tcpdump 可能按协商的 wscale 显示"缩放后"的窗口, 也可能显示原始 16 位值 --
            判"首个窗口通告"必须看**原始 16 位 win 字段**(SYN 里的窗口按定义是未缩放的),
            所以这里自己解包, 把 win_raw 与 wscale 选项分别打出来.

支持: linktype 1 (EN10MB, Linux lo 用这个) 与 113 (SLL). IPv4/TCP only.
本件只报字段, 不做判据结论.
"""
import struct
import sys


def pcap_packets(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 24:
        raise SystemExit("too short")
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian, nano = "<", False
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian, nano = ">", False
    elif magic == b"\x4d\x3c\xb2\xa1":
        endian, nano = "<", True
    elif magic == b"\xa1\xb2\x3c\x4d":
        endian, nano = ">", True
    else:
        raise SystemExit("not a pcap (magic %r)" % magic)
    vmaj, vmin, tz, sig, snap, linktype = struct.unpack(endian + "HHiIII", data[4:24])
    yield ("_hdr", (linktype, snap, vmaj, vmin, nano))
    off = 24
    n = 0
    while off + 16 <= len(data):
        ts_s, ts_u, incl, orig = struct.unpack(endian + "IIII", data[off:off + 16])
        off += 16
        pkt = data[off:off + incl]
        off += incl
        n += 1
        t = ts_s + (ts_u / 1e9 if nano else ts_u / 1e6)
        yield ("pkt", (n, t, pkt, orig))


def parse(path):
    linktype = None
    for kind, payload in pcap_packets(path):
        if kind == "_hdr":
            linktype, snap, vmaj, vmin, nano = payload
            print("PCAP_HDR linktype=%d snap=%d version=%d.%d nano=%s"
                  % (linktype, snap, vmaj, vmin, nano))
            continue
        idx, t, pkt, orig = payload
        l3 = None
        if linktype == 1:
            if len(pkt) < 14:
                continue
            eth_type = struct.unpack(">H", pkt[12:14])[0]
            if eth_type != 0x0800:
                print("PKT %d t=%.6f NON_IPV4 ethertype=0x%04x" % (idx, t, eth_type))
                continue
            l3 = 14
        elif linktype == 113:
            if len(pkt) < 16:
                continue
            eth_type = struct.unpack(">H", pkt[14:16])[0]
            if eth_type != 0x0800:
                print("PKT %d t=%.6f NON_IPV4 ethertype=0x%04x" % (idx, t, eth_type))
                continue
            l3 = 16
        else:
            raise SystemExit("unsupported linktype %d" % linktype)
        if len(pkt) < l3 + 20:
            continue
        ihl = (pkt[l3] & 0x0F) * 4
        proto = pkt[l3 + 9]
        if proto != 6:
            print("PKT %d t=%.6f NON_TCP proto=%d" % (idx, t, proto))
            continue
        tot = struct.unpack(">H", pkt[l3 + 2:l3 + 4])[0]
        t4 = l3 + ihl
        if len(pkt) < t4 + 20:
            continue
        sport, dport, seq, ack, off_flags, win, csum, urg = struct.unpack(
            ">HHIIHHHH", pkt[t4:t4 + 20])
        doff = ((off_flags >> 12) & 0xF) * 4
        flags = off_flags & 0x1FF
        fnames = []
        for bit, nm in ((0x100, "NS"), (0x080, "CWR"), (0x040, "ECE"), (0x020, "URG"),
                        (0x010, "ACK"), (0x008, "PSH"), (0x004, "RST"),
                        (0x002, "SYN"), (0x001, "FIN")):
            if flags & bit:
                fnames.append(nm)
        opts = pkt[t4 + 20:t4 + doff]
        wscale = None
        mss = None
        sackok = False
        tsval = None
        i = 0
        while i < len(opts):
            k = opts[i]
            if k == 0:
                break
            if k == 1:
                i += 1
                continue
            if i + 1 >= len(opts):
                break
            ln = opts[i + 1]
            if ln < 2 or i + ln > len(opts):
                break
            if k == 2 and ln == 4:
                mss = struct.unpack(">H", opts[i + 2:i + 4])[0]
            elif k == 3 and ln == 3:
                wscale = opts[i + 2]
            elif k == 4 and ln == 2:
                sackok = True
            elif k == 8 and ln == 10:
                tsval = struct.unpack(">I", opts[i + 2:i + 6])[0]
            i += ln
        payload_len = max(0, tot - ihl - doff)
        print("PKT %d t=%.6f %s:%d > %s:%d flags=[%s] win_raw=%d (0x%04x) "
              "seq=%d ack=%d wscale=%s mss=%s sackOK=%s tsval=%s datalen=%d orig=%d"
              % (idx, t, "", sport, "", dport, ",".join(fnames) or "-", win, win,
                 seq, ack, wscale, mss, sackok, tsval, payload_len, orig))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: parse_pcap_tcp.py <file.pcap>")
    parse(sys.argv[1])
