#!/usr/bin/env python3
"""P5d exp2: build stimulus frames for the HLS slot-leak reproduction.

Emits, into the directory given as argv[1]:
  frames_b.memh    one hex byte per line (all frames concatenated)
  frames_meta.memh line 0 : nframes
                   line i+1: "<offset> <length> <tag>"   (tag = decimal marker)

Frames target the HLS DUT MAC 00:0A:35:01:FE:C0 (layer_mac.cpp is_unicast),
IPv4/TCP, dport 8080 (TCP_PORT_ECHO), peer 192.168.100.1 -> 192.168.100.2.
TCP checksum is NOT validated by the HLS rx path (layer_tcp.cpp: only
ip_rx.valid is checked) so it is written as 0; the IP checksum IS validated
(layer_ip.cpp:73) and is computed properly.
"""
import os
import struct
import sys

DUT_MAC = bytes.fromhex("000a3501fec0")
PEER_MAC = bytes.fromhex("112233445566")
DUT_IP = bytes([192, 168, 100, 2])
PEER_IP = bytes([192, 168, 100, 1])
DPORT = 8080

TCP_FIN, TCP_SYN, TCP_RST, TCP_PSH, TCP_ACK = 0x01, 0x02, 0x04, 0x08, 0x10


def ip_csum(b):
    if len(b) % 2:
        b += b"\x00"
    s = 0
    for i in range(0, len(b), 2):
        s += (b[i] << 8) | b[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def eth_ip_tcp(sport, seq, ack, flags, payload=b"", mss=None, ipid=0):
    opts = b""
    if mss is not None:
        opts = bytes([2, 4]) + struct.pack(">H", mss)
    while len(opts) % 4:
        opts += b"\x00"
    doff = (20 + len(opts)) // 4
    tcp = struct.pack(">HHIIBBHHH", sport, DPORT, seq, ack,
                      (doff << 4), flags, 0xC000, 0, 0) + opts + payload
    total = 20 + len(tcp)
    ip = struct.pack(">BBHHHBBH", 0x45, 0, total, ipid, 0x4000, 64, 6, 0) \
        + PEER_IP + DUT_IP
    ip = ip[:10] + struct.pack(">H", ip_csum(ip)) + ip[12:]
    # frame = preamble + eth + ip + tcp + pad + FCS(ignored by HLS rx)
    f = b"\x55" * 7 + b"\xd5" + DUT_MAC + PEER_MAC + b"\x08\x00" + ip + tcp
    if len(f) < 60:
        f += b"\x00" * (60 - len(f))
    return f + b"\xde\xad\xbe\xef"


PEER_ISN = 0x20000000
OUR_ISN1 = 0x12345679          # cid 0: ISS = 0x12345678|cid<<20, +1 after SYN
SPORT_A = 12345
SPORT_B = 12346


def build():
    fr = []

    def add(tag, b):
        fr.append((tag, b))

    # ---- tuple A: full handshake (HLS should reach T_ESTABLISHED) ----
    add("A1 SYN", eth_ip_tcp(SPORT_A, PEER_ISN, 0, TCP_SYN, mss=1460))
    add("A2 ACK", eth_ip_tcp(SPORT_A, PEER_ISN + 1, OUR_ISN1, TCP_ACK))
    # KEY TEST A: same 4-tuple brand-new SYN after a *local* teardown.
    # Nothing is sent to the HLS here -- that is exactly the point: the fast
    # path's abort/timeout RST never reaches HLS, so the slot is still held.
    add("A3 SYN-retry", eth_ip_tcp(SPORT_A, PEER_ISN, 0, TCP_SYN, mss=1460))

    # ---- tuple B: SYN only (HLS stays in T_SYN_RCVD) ----
    add("B1 SYN", eth_ip_tcp(SPORT_B, PEER_ISN, 0, TCP_SYN, mss=1460))
    # KEY TEST B: same 4-tuple SYN again while HLS is in T_SYN_RCVD.
    add("B2 SYN-retry", eth_ip_tcp(SPORT_B, PEER_ISN, 0, TCP_SYN, mss=1460))

    # ---- peer FIN on tuple A: the ONE path that does free the HLS slot ----
    add("A4 FIN", eth_ip_tcp(SPORT_A, PEER_ISN + 1, OUR_ISN1, TCP_FIN | TCP_ACK))
    # positive control: after the peer FIN the slot must be reusable
    add("A5 SYN-again", eth_ip_tcp(SPORT_A, PEER_ISN, 0, TCP_SYN, mss=1460))

    # ---- slot exhaustion: 4 distinct tuples, no teardown at all ----
    for i, sp in enumerate((20001, 20002, 20003, 20004)):
        add("X%d SYN" % (i + 1), eth_ip_tcp(sp, PEER_ISN, 0, TCP_SYN, mss=1460))

    return fr


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    fr = build()
    blob = b"".join(b for _, b in fr)
    with open(os.path.join(out, "frames_b.memh"), "w") as f:
        for i, byte in enumerate(blob):
            f.write("%02x\n" % byte)
    off = 0
    # numbers only -- $fscanf in the TB reads these with plain %d
    with open(os.path.join(out, "frames_meta.memh"), "w") as f:
        f.write("%d\n" % len(fr))
        for tag, b in fr:
            f.write("%d %d\n" % (off, len(b)))
            off += len(b)
    # tag list kept in a side file for the Python analyser
    with open(os.path.join(out, "frames_tags.txt"), "w") as f:
        for tag, _ in fr:
            f.write("%s\n" % tag)
    print("frames=%d bytes=%d -> %s" % (len(fr), len(blob), out))
    for tag, b in fr:
        print("  %-14s len=%d" % (tag, len(b)))


if __name__ == "__main__":
    main()
