#!/usr/bin/env python
"""udp_tx_frame 全链刺激生成 + GMII 帧解码验证 (头字段/双校验和/载荷/FCS/pad/统计)。"""
import os
import struct
import zlib

SRC_MAC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0])
DST_MAC = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
SRC_IP = 0x0A000001
DST_IP = 0xC0A86402
SPORT, DPORT = 12345, 8080
LENS = [0, 1, 2, 3, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 42, 100, 1500, 42, 17, 6]


def payload(n):
    return bytes(((i * 7 + 3) & 0xFF) for i in range(n))


def words_of(pl):
    ws = []
    if not pl:
        ws.append((0, 0, 1))          # 零长帧: 单拍 tlast 且 tkeep=0
        return ws
    for k in range(0, len(pl), 8):
        chunk = pl[k:k + 8]
        w = int.from_bytes(chunk.ljust(8, b"\x00"), "big")
        keep = (0xFF << (8 - len(chunk))) & 0xFF
        ws.append((w, keep, k + 8 >= len(pl)))
    return ws


def csum16(hw):
    s = sum(hw)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def ip_csum_ref(tlen, idv):
    hw = [0x4500, tlen & 0xFFFF, idv & 0xFFFF, 0x0000, 0x4011, 0x0000,
          (SRC_IP >> 16) & 0xFFFF, SRC_IP & 0xFFFF,
          (DST_IP >> 16) & 0xFFFF, DST_IP & 0xFFFF]
    return csum16(hw)


def udp_csum_ref(pl):
    pseudo = [(SRC_IP >> 16) & 0xFFFF, SRC_IP & 0xFFFF,
              (DST_IP >> 16) & 0xFFFF, DST_IP & 0xFFFF,
              0x0011, len(pl) + 8]
    hdr = [SPORT, DPORT, len(pl) + 8, 0]
    hws = []
    for i in range(0, len(pl), 2):
        b = pl[i:i + 2]
        hws.append((b[0] << 8) | (b[1] if len(b) > 1 else 0))
    return csum16(pseudo + hdr + hws)


def build_script():
    script = []
    frames = []
    for n in LENS:
        pl = payload(n)
        for w, k, l in words_of(pl):
            script.append(('W', w, k, l))
        frames.append(pl)
    return script, frames


def generate(simdir):
    script, frames = build_script()
    ty, d, k, l, n = [], [], [], [], []
    for s in script:
        if s[0] == 'W':
            ty.append(1); d.append(s[1]); k.append(s[2]); l.append(1 if s[3] else 0); n.append(0)
        else:
            ty.append(0); d.append(0); k.append(0); l.append(0); n.append(s[1])

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    w('txp_ty.memh', ty, '%X')      # $readmemh 十六进制
    w('txp_data.memh', d, '%016X')
    w('txp_keep.memh', k, '%02X')
    w('txp_last.memh', l, '%X')
    w('txp_gap.memh', n, '%X')
    return frames


def parse_gmii(fn):
    """GMII 流 -> 帧字节列表 (剥前导 55x7+D5, 含 FCS)。"""
    frames = []
    cur = []
    active = False
    with open(fn) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('STATS'):
                continue
            parts = line.split()
            if len(parts) != 2:
                continue
            en, b = parts
            if en == '1':
                cur.append(int(b, 16))
                active = True
            elif active:
                frames.append(bytes(cur))
                cur = []
                active = False
    return frames


def check_frame(fb, pl, idx, csum_en):
    """验证一帧: 返回错误字符串或 None。帧 = 前导8 + 内容 + FCS4。"""
    errs = []
    if len(fb) < 12:
        return 'runt %d' % len(fb)
    pre = fb[:8]
    if pre != bytes([0x55] * 7 + [0xD5]):
        errs.append('preamble %s' % pre.hex())
    body = fb[8:-4]
    fcs = fb[-4:]
    if struct.pack('<I', zlib.crc32(fb[8:-4]) & 0xFFFFFFFF) != fcs:
        errs.append('fcs %s vs %s' % (fcs.hex(),
                                      struct.pack('<I', zlib.crc32(fb[8:-4]) & 0xFFFFFFFF).hex()))
    n = len(pl)
    elen = max(60, 42 + n)   # pad 基准 = 60B 内容 (含 14B 以太头)
    if len(body) != elen:
        errs.append('len %d != %d' % (len(body), elen))
    if body[:6] != DST_MAC:
        errs.append('dst_mac')
    if body[6:12] != SRC_MAC:
        errs.append('src_mac')
    if body[12:14] != b'\x08\x00':
        errs.append('ethertype')
    if body[14] != 0x45:
        errs.append('ver/ihl %02x' % body[14])
    if body[22] != 0x40 or body[23] != 0x11:
        errs.append('ttl/proto %02x%02x' % (body[22], body[23]))
    if struct.unpack('!H', body[16:18])[0] != n + 28:
        errs.append('total_len')
    if struct.unpack('!H', body[18:20])[0] != idx & 0xFFFF:
        errs.append('id %d != %d' % (struct.unpack('!H', body[18:20])[0], idx))
    iph = struct.unpack('!10H', body[14:34])
    s = sum(iph)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        errs.append('ip_csum %04x' % s)
    if body[34:36] != struct.pack('!H', SPORT) or body[36:38] != struct.pack('!H', DPORT):
        errs.append('ports')
    if struct.unpack('!H', body[38:40])[0] != n + 8:
        errs.append('udp_len')
    uc = struct.unpack('!H', body[40:42])[0]
    if csum_en:
        if uc != udp_csum_ref(pl):
            errs.append('udp_csum %04x != %04x' % (uc, udp_csum_ref(pl)))
    else:
        if uc != 0:
            errs.append('udp_csum0 %04x' % uc)
    if body[42:42 + n] != pl:
        errs.append('payload')
    if any(body[42 + n:]):
        errs.append('pad nonzero')
    return ';'.join(errs) if errs else None


def check(simdir, csum_en):
    frames = generate(simdir)
    fn = os.path.join(simdir, 'resp_udp_tx_csum0.memh' if not csum_en else 'resp_udp_tx.memh')
    if not os.path.exists(fn):
        return False, ['missing %s' % fn]
    got = parse_gmii(fn)
    errs = []
    if len(got) != len(frames):
        errs.append('frame count %d != %d' % (len(got), len(frames)))
    for i, (fb, pl) in enumerate(zip(got[:len(frames)], frames)):
        e = check_frame(fb, pl, i, csum_en)
        if e:
            errs.append('frame %d (len %d): %s' % (i, len(pl), e))
    # 统计
    stats = None
    with open(fn) as fh:
        for line in fh:
            if line.startswith('STATS'):
                stats = [int(x) for x in line.split()[1:]]
    if stats != [len(frames), sum(len(p) for p in frames)]:
        errs.append('stats %s' % stats)
    return (not errs), errs


if __name__ == '__main__':
    import sys
    simdir = sys.argv[1] if len(sys.argv) > 1 else 'sim'
    script, frames = build_script()
    print('%d frames, %d script lines' % (len(frames), len(script)))
