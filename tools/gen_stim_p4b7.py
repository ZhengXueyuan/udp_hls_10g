#!/usr/bin/env python
"""P4b-7-P6 板测冻结复现: p4b7_syn.pcapng PC->FPGA 全流重放。

reuse gen_stim_p4_chain.py 的 replay 设施 (build_replay_frames + gen_memh):
- pcapng -> JSON: PC->FPGA 方向 (src 192.168.100.1), 去掉握手帧 (SYN/SYNACK/PC-ACK,
  由合成 prelude 顶替 — 捕获内的 SYN 重放会触发第二次握手, 破坏流), 首数据帧起
  到窗口尾。
- 帧 = pktmon 全帧 (无 FCS, IP csum 无效 — build_replay_frames 重算)。
- 变量: (b) ack 字段 -> 握手常量 HS_ACKVAL; (c) 帧间空隙 +extra 拍 (去背靠背)。
用法: python gen_stim_p4b7.py <simdir> [end_t] [b|c [extra]]
"""
import json
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_p4_chain as G

PC_SRC = '192.168.100.1'
HS_ACKVAL = G.HS_ACKVAL          # 0x12345679 — 握手常量 (= 板级 ISS+1 305419897)
SYN_T = 1788642684.841          # pcap 内 SYN 时刻 (参考, 不用于窗口)
FLOOD0_T = 1788642684.865081    # 首数据帧时刻 (重放起点)

def parse_pcap(fn):
    data = open(fn, 'rb').read()
    frames = []
    i = 0
    while i + 12 <= len(data):
        btype, blen = struct.unpack('<II', data[i:i + 8])
        if blen < 12 or i + blen > len(data):
            break
        if btype == 6:
            body = data[i + 8:i + blen - 4]
            ifid, tsh, tsl, caplen, origlen = struct.unpack('<IIIII', body[:20])
            frames.append(((tsh * 2**32 + tsl) / 1e6, body[20:20 + caplen]))
        i += blen
    return frames

def main():
    simdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'sim', 'p4sim')
    end_t = float(sys.argv[2]) if len(sys.argv) > 2 else 0
    variant = sys.argv[3] if len(sys.argv) > 3 else 'a'
    extra = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    cap = os.path.join(ROOT, 'p4b7_syn.pcapng')
    frames = parse_pcap(cap)
    rows = []
    for ts, p in frames:
        if len(p) < 54 or p[12:14] != b'\x08\x00':
            continue
        ip = p[14:]
        if ip[9] != 6:
            continue
        src = '%d.%d.%d.%d' % tuple(ip[12:16])
        if src != PC_SRC:
            continue
        rows.append((ts, p))
    # 去掉握手帧 (前 2 帧: SYN + PC ACK) — 由 prelude 顶替
    w0 = FLOOD0_T - 1e-6
    if not rows or rows[0][0] > FLOOD0_T + 1e-3:
        print('FATAL: pcap parse failed (no PC frames)')
        sys.exit(1)
    w1 = end_t if end_t > w0 else rows[-1][0] + 1e-6
    jrows = [[t, p.hex()] for t, p in rows if w0 <= t <= w1]
    jfn = os.path.join(ROOT, 'p4b7_p2f.json')
    with open(jfn, 'w') as fh:
        json.dump(jrows, fh)
    print('JSON: %d frames [%.6f, %.6f] -> %s' % (len(jrows), w0, w1, jfn))
    F = G.build_replay_frames(jfn, w0=w0, w1=w1, n_warmup=0)
    if not F:
        sys.exit(1)
    n = 0
    for f in F:
        if f['name'].startswith('rp'):
            n += 1
            if variant == 'b':
                # piggyback ack -> 握手常量 (ack 不推进 snd_una);
                # extra>0: 仅前 extra 帧 (定位单帧触发)
                if not extra or n <= extra:
                    fb = bytearray(f['fb'])
                    fb[42:46] = struct.pack('!I', HS_ACKVAL)
                    f['fb'] = bytes(fb)
                    # ack 改动后必须重算 FCS (zlib 值小端), 否则 MAC 整帧拒收
                    f['fcs'] = struct.pack('<I', zlib.crc32(f['fb']) & 0xFFFFFFFF)
            if variant == 'c':
                f['gap'] += extra
    G.gen_memh(simdir, F)
    print('memh written: %d replay frames (variant %s, extra=%d)' % (n, variant, extra))
    # 总刺激长度报数
    off = 0
    for f in F:
        off += f['gap']
        f['first'] = off + 8
        f['B'] = len(f['fb'])
        off += 8 + f['B'] + 4 + 12
    print('total stim cycles ~= %d (%.2fM, 4M 上限)' % (off, off / 1e6))

if __name__ == '__main__':
    main()
