#!/usr/bin/env python
"""全链 echo 刺激生成 + 期望回发帧验证。

链路: GMII -> mac_rx_64 -> udp_rx -> udp_echo -> udp_tx_frame -> mac_tx_64 -> GMII
回发帧: dst/src MAC、dst/src IP、dst/src port 交换 (dst = 原帧 src), 载荷一致,
IP/UDP 校验和好, FCS 好, id 按回发序号递增。坏 CRC 匹配帧不回声, 不匹配帧不回声。
"""
import os
import struct
import zlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_stim_udp_rx import mk_frame, PRE, IFG, SRC_MAC, SRC_IP, SPORT, DPORT
from gen_stim_udp_rx import payload as pl

MY_MAC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC1])
MY_IP = 0xC0A86402          # 192.168.100.2
MY_PORT = DPORT             # 8080
LENS = [0, 1, 2, 3, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 42, 100, 1500]


def build_frames():
    """(名称, 帧字节, fcs, 是否期望回发) 列表。"""
    F = []
    for n in LENS:
        fb, fcs = mk_frame(SRC_IP, MY_IP, SPORT, DPORT, n)
        F.append(('len%d' % n, fb, fcs, True))
    fb, fcs = mk_frame(SRC_IP, MY_IP, SPORT, DPORT, 42, bad_fcs=True)
    F.append(('badcrc', fb, fcs, False))
    fb, fcs = mk_frame(SRC_IP, MY_IP, SPORT, 9999, 42)
    F.append(('portmismatch', fb, fcs, False))
    for nm, n in (('b2b1', 17), ('b2b2', 42), ('b2b3', 6)):
        fb, fcs = mk_frame(SRC_IP, MY_IP, SPORT, DPORT, n)
        F.append((nm, fb, fcs, True))
    return F


def generate(simdir):
    frames = build_frames()
    segs = []
    for nm, fb, fcs, _ in frames:
        segs += [(0, b, 1) for b in (PRE + fb + fcs)]
        segs += [(0, b, 0) for b in IFG]
    data = [s[1] for s in segs]
    dv = [s[2] for s in segs]
    er = [0] * len(segs)

    def w(fn, vals, fmt):
        with open(os.path.join(simdir, fn), 'w') as fh:
            fh.write('\n'.join(fmt % v for v in vals) + '\n')
    w('stim_data.memh', data, '%02X')
    w('stim_dv.memh', dv, '%X')
    w('stim_er.memh', er, '%X')
    return frames


def csum16(hw):
    s = sum(hw)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def check_frame(fb, n, idx):
    """验证回发帧: dst=原src, src=MY, 载荷=payload(n), id=idx。返回错误串或 None。"""
    errs = []
    if len(fb) < 12:
        return 'runt'
    if fb[:8] != bytes([0x55] * 7 + [0xD5]):
        errs.append('preamble')
    body = fb[8:-4]
    fcs = fb[-4:]
    if struct.pack('<I', zlib.crc32(fb[8:-4]) & 0xFFFFFFFF) != fcs:
        errs.append('fcs')
    elen = max(60, 42 + n)   # pad 基准 = 60B 内容 (含 14B 以太头)
    if len(body) != elen:
        errs.append('len %d != %d' % (len(body), elen))
    if body[:6] != SRC_MAC:
        errs.append('dst_mac (应=原 src)')
    if body[6:12] != MY_MAC:
        errs.append('src_mac (应=MY)')
    if body[12:14] != b'\x08\x00':
        errs.append('ethertype')
    if body[14] != 0x45:
        errs.append('ver/ihl')
    if body[22] != 0x40 or body[23] != 0x11:
        errs.append('ttl/proto')
    if struct.unpack('!H', body[16:18])[0] != n + 28:
        errs.append('total_len')
    if struct.unpack('!H', body[18:20])[0] != idx & 0xFFFF:
        errs.append('id')
    iph = struct.unpack('!10H', body[14:34])
    s = sum(iph)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        errs.append('ip_csum')
    if struct.unpack('!I', body[26:30])[0] != MY_IP:
        errs.append('src_ip')
    if struct.unpack('!I', body[30:34])[0] != SRC_IP:
        errs.append('dst_ip (应=原 src)')
    if body[34:36] != struct.pack('!H', MY_PORT):
        errs.append('src_port')
    if body[36:38] != struct.pack('!H', SPORT):
        errs.append('dst_port (应=原 src)')
    if struct.unpack('!H', body[38:40])[0] != n + 8:
        errs.append('udp_len')
    hws = []
    p = pl(n)
    for i in range(0, n, 2):
        b = p[i:i + 2]
        hws.append((b[0] << 8) | (b[1] if len(b) > 1 else 0))
    # 回发帧 UDP 校验和: 伪头 (src=MY, dst=原src) + UDP 头 (MY_PORT->SPORT) + 载荷
    ref = csum16([(MY_IP >> 16) & 0xFFFF, MY_IP & 0xFFFF,
                  (SRC_IP >> 16) & 0xFFFF, SRC_IP & 0xFFFF, 0x0011, n + 8,
                  MY_PORT, SPORT, n + 8, 0] + hws)
    uc = struct.unpack('!H', body[40:42])[0]
    if uc != ref:
        errs.append('udp_csum %04x != %04x' % (uc, ref))
    if body[42:42 + n] != pl(n):
        errs.append('payload')
    if any(body[42 + n:]):
        errs.append('pad')
    return ';'.join(errs) if errs else None


def parse_gmii(fn):
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


def check(simdir):
    frames = generate(simdir)
    fn = os.path.join(simdir, 'resp_echo.memh')
    if not os.path.exists(fn):
        return False, ['missing %s' % fn]
    got = parse_gmii(fn)
    # 期望回发 = 好匹配帧: 原载荷长度序列
    exp_lens = []
    for nm, fb, fcs, e in frames:
        if e:
            exp_lens.append(int(nm[3:]) if nm.startswith('len') else
                            (17 if nm == 'b2b1' else 42 if nm == 'b2b2' else 6))
    errs = []
    if len(got) != len(exp_lens):
        errs.append('echo count %d != %d' % (len(got), len(exp_lens)))
    for i, (fb, n) in enumerate(zip(got[:len(exp_lens)], exp_lens)):
        e = check_frame(fb, n, i)
        if e:
            errs.append('echo %d (len %d): %s' % (i, n, e))
    stats = None
    with open(fn) as fh:
        for line in fh:
            if line.startswith('STATS'):
                stats = [int(x) for x in line.split()[1:]]
    exp_stats = [len(exp_lens), 1, len(exp_lens), sum(exp_lens)]
    if stats != exp_stats:
        errs.append('stats %s != %s' % (stats, exp_stats))
    return (not errs), errs


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else 'sim'
    frames = generate(simdir)
    print('%d frames' % len(frames))
