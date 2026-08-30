#!/usr/bin/env python
"""P4b 排障: HLS 孤立探针刺激+校验 — 直喂 udp_echo (新 slowstack_prj RTL):
ARP 请求 + UDP 帧, 捕 tx_stream 全帧, 校验 UDP echo 载荷逐字节。
绕过 mac_rx_64/rx_classify/slow_rx_adp/slow_tx_adp — 定位载荷污染归属。
用法: gen_hls_udp_probe.py <simdir> [check]
"""
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_p4_chain as G

PRE = bytes([0x55] * 7) + b'\xD5'


def payload(n):
    return bytes(((i * 7 + 3) & 0xFF) for i in range(n))


def gen(simdir):
    os.makedirs(simdir, exist_ok=True)
    arp_fb, _fcs = G.mk_arp_req()          # 60B content
    udp_fb, _fcs, _pl = G.mk_udp()          # 66B content
    frames = [arp_fb, udp_fb]
    with open(os.path.join(simdir, 'hls_stim.memh'), 'w') as fh:
        for fb in frames:
            for b in PRE + fb:
                fh.write('%02X\n' % b)
    with open(os.path.join(simdir, 'hls_stim_last.memh'), 'w') as fh:
        for fb in frames:
            for j in range(len(PRE) + len(fb)):
                fh.write('%d\n' % (1 if j == len(PRE) + len(fb) - 1 else 0))
    print('stim written: %d frames, %d bytes'
          % (len(frames), sum(len(PRE) + len(f) for f in frames)))


def parse_tx(fn):
    """tx_stream 字节流 -> 帧列表 (按 tlast 切)。每行 3 hex 位: {tlast,byte}。"""
    frames, cur = [], []
    with open(fn) as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln or ln == 'END':
                continue
            v = int(ln, 16)
            cur.append(v & 0xFF)
            if v & 0x100:
                frames.append(cur)
                cur = []
    return frames


def check(simdir):
    frames = parse_tx(os.path.join(simdir, 'hls_udp_probe_tx.memh'))
    print('TX frames:', len(frames))
    errs = []
    udp_seen = False
    for i, f in enumerate(frames):
        if len(f) < 8 + 14:
            errs.append('frame %d runt len=%d' % (i, len(f)))
            continue
        # 剥 HLS mac_tx 的 8B 前导 (55x7+d5)
        body = bytes(f[8:])
        et = struct.unpack('!H', body[12:14])[0]
        if et != 0x0800:
            continue
        proto = body[23]
        if proto == 17:
            udp_seen = True
            ihl = (body[14] & 0xF) * 4
            uh = body[14 + ihl:]
            pl = uh[8:]
            exp = payload(len(pl))
            print('frame %d: udp echo, payload %d bytes' % (i, len(pl)))
            for j in range(len(pl)):
                if pl[j] != exp[j]:
                    print('  byte %d: got %02x exp %02x' % (j, pl[j], exp[j]))
            if pl != exp:
                errs.append('udp payload mismatch')
            # FCS 自检 (HLS TX 附带 FCS, LSB-first; 覆盖 8B 前导+内容)
            fcs = f[-4:]
            if struct.pack('<I', zlib.crc32(bytes(f[:-4])) & 0xFFFFFFFF) != bytes(fcs):
                errs.append('udp echo fcs bad')
    if not udp_seen:
        errs.append('no udp echo frame captured')
    if errs:
        for e in errs:
            print('FAIL:', e)
        return False
    print('HLS UDP PROBE OK')
    return True


if __name__ == '__main__':
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'p4sim_hlsprobe')
    if len(sys.argv) > 2 and sys.argv[2] == 'check':
        sys.exit(0 if check(simdir) else 1)
    gen(simdir)
