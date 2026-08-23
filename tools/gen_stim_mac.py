#!/usr/bin/env python
"""mac_rx_64 xsim 刺激生成: stim_data/dv/er.memh + expected.memh + expected_stats.txt

帧列表 (11 帧): arp60 / udp64 / long1514 / vlan / btb_a / btb_b (背靠背) /
badcrc (坏 CRC) / runt46 / longpre (长前导) / garbage (垃圾字节+前导) / rxerr (帧内 rx_er)。
FCS 按线上 LSB-first 字节序 (zlib.crc32 小端) — 与 udp_hls_eco 铁律一致。
"""
import struct
import zlib
import os
import sys


def eth_fcs(p):
    return struct.pack('<I', zlib.crc32(p) & 0xFFFFFFFF)


DST = bytes([0xFF] * 6)
SRC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0])
PRE = bytes([0x55] * 7) + bytes([0xD5])
IFG = bytes([0x07] * 12)


def mk_frame(dst, src, etype, body):
    p = dst + src + etype + body
    return p + eth_fcs(p)


def build_frames():
    f = []
    f.append(dict(name="arp60", pre=PRE, fb=mk_frame(DST, SRC, b"\x08\x06", bytes(range(46)))))
    f.append(dict(name="udp64", pre=PRE, fb=mk_frame(DST, SRC, b"\x08\x00", bytes(range(46)))))
    f.append(dict(name="long1514", pre=PRE,
                  fb=mk_frame(DST, SRC, b"\x08\x00", bytes((i * 7 + 3) & 0xFF for i in range(1500)))))
    f.append(dict(name="vlan", pre=PRE, fb=mk_frame(DST, SRC, b"\x81\x00\x00\x64\x08\x00", bytes(range(42)))))
    f.append(dict(name="btb_a", pre=PRE, fb=mk_frame(DST, SRC, b"\x08\x00", bytes(range(46)))))
    f.append(dict(name="btb_b", pre=PRE, fb=mk_frame(DST, SRC, b"\x08\x00", bytes(range(46, 92)))))
    bad = bytearray(f[1]["fb"])
    bad[20] ^= 0x55
    f.append(dict(name="badcrc", pre=PRE, fb=bytes(bad)))
    f.append(dict(name="runt46", pre=PRE, fb=mk_frame(DST, SRC, b"\x08\x00", bytes(range(28)))))
    f.append(dict(name="longpre", pre=bytes([0x55] * 10) + bytes([0xD5]), fb=f[0]["fb"]))
    f.append(dict(name="garbage", pre=b"\xAA\xBB\xCC" + bytes([0x55] * 8) + bytes([0xD5]), fb=f[1]["fb"]))
    f.append(dict(name="rxerr", pre=PRE, fb=f[1]["fb"], er_at=30))
    return f


def expected_words(frames):
    out = []
    for fr in frames:
        payload = fr["fb"][:-4]
        first = True
        for k in range(0, len(payload), 8):
            chunk = payload[k:k + 8]
            w = int.from_bytes(chunk.ljust(8, b"\x00"), "big")
            keep = (0xFF << (8 - len(chunk))) & 0xFF
            last = (k + 8 >= len(payload))
            # crs/err 仅 TLAST 词有效 (RTL 约定)
            crs = (1 if fr["name"] != "badcrc" else 0) if last else 0
            err = (1 if "er_at" in fr else 0) if last else 0
            out.append("%016X %02X %d %d %d %d" % (w, keep, int(first), int(last), crs, err))
            first = False
    return out


def generate(simdir):
    frames = build_frames()
    data, dv, er = [], [], []
    for fr in frames:
        seg = list(fr["pre"]) + list(fr["fb"])
        dvv = [1] * len(seg)
        err = [0] * len(seg)
        if "er_at" in fr:
            err[len(fr["pre"]) + fr["er_at"]] = 1
        data += seg
        dv += dvv
        er += err
        data += list(IFG)
        dv += [0] * len(IFG)
        er += [0] * len(IFG)
    with open(os.path.join(simdir, "stim_data.memh"), "w") as fh:
        fh.write("\n".join("%02X" % b for b in data) + "\n")
    with open(os.path.join(simdir, "stim_dv.memh"), "w") as fh:
        fh.write("\n".join("%d" % b for b in dv) + "\n")
    with open(os.path.join(simdir, "stim_er.memh"), "w") as fh:
        fh.write("\n".join("%d" % b for b in er) + "\n")
    with open(os.path.join(simdir, "expected.memh"), "w") as fh:
        fh.write("\n".join(expected_words(frames)) + "\n")
    total = sum(len(fr["fb"]) for fr in frames)
    with open(os.path.join(simdir, "expected_stats.txt"), "w") as fh:
        fh.write("%d %d %d %d\n" % (len(frames), 1, 0, total))
    return frames


if __name__ == "__main__":
    generate(sys.argv[1] if len(sys.argv) > 1 else "sim")
