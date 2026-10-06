#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""s2_bidir_analyze.py (v2) -- 双向 pcap: 对端 dup-ACK 序列 vs 板侧重传
   修复 v1 的键错误: v1 按 (src,sport,dport) 分键 ⇒ 对端->板的 ACK 落在另一个键里被跳过。
   v2 按**连接** (= 对端端口) 归并两个方向。
"""
import struct, sys, collections

path = sys.argv[1] if len(sys.argv) > 1 else 's2_bidir.pcap'
d = open(path, 'rb').read()
off = 24
conns = collections.defaultdict(list)   # peer_port -> [(t, dir, seq, ack, flags, plen, win)]
while off + 16 <= len(d):
    ts, tu, incl, orig = struct.unpack('<IIII', d[off:off+16]); off += 16
    if off + incl > len(d):
        print("NOTE: truncated last record"); break
    pkt = d[off:off+incl]; off += incl
    if len(pkt) < 54 or struct.unpack('>H', pkt[12:14])[0] != 0x0800: continue
    ihl = (pkt[14] & 0x0f) * 4
    if pkt[23] != 6: continue
    total = struct.unpack('>H', pkt[16:18])[0]
    tcp = 14 + ihl
    sport, dport, seq, ack, of = struct.unpack('>HHIIH', pkt[tcp:tcp+14])
    doff = (of >> 12) * 4; flags = of & 0x1ff
    win = struct.unpack('>H', pkt[tcp+14:tcp+16])[0]
    plen = total - ihl - doff
    src = '.'.join(str(b) for b in pkt[26:30])
    peer_port = dport if src == '192.168.100.2' else sport
    conns[peer_port].append((ts + tu*1e-6, 'B' if src == '192.168.100.2' else 'P',
                             seq, ack, flags, plen, win))

tot = collections.Counter()
detail = []
allretx_duprun = []
for pp, pk in sorted(conns.items()):
    pk.sort()
    seen = set()
    last_ack = None
    dup_run = 0
    max_run = 0
    nack = 0
    nretx = 0
    retx_events = []
    for (t, dr, seq, ack, flags, plen, win) in pk:
        if dr == 'B':
            if plen > 0:                      # 板->对端 数据段
                if seq in seen:
                    nretx += 1
                    retx_events.append((t, seq, plen, dup_run))
                seen.add(seq)
        else:                                  # 对端->板
            if plen == 0 and (flags & 0x10) and not (flags & 0x03):
                nack += 1
                if last_ack is not None and ack == last_ack:
                    dup_run += 1
                    max_run = max(max_run, dup_run)
                else:
                    dup_run = 0
                last_ack = ack
    tot['retx'] += nretx
    tot['dupacks_total'] += sum(1 for _ in ())  # placeholder
    # dup-ACK 总数 = 所有 run>0 的累计
    dup_total = 0
    last_ack = None; run = 0; run3 = 0
    for (t, dr, seq, ack, flags, plen, win) in pk:
        if dr == 'P' and plen == 0 and (flags & 0x10) and not (flags & 0x03):
            if last_ack is not None and ack == last_ack:
                run += 1; dup_total += 1
            else:
                if run >= 3: run3 += 1
                run = 0
            last_ack = ack
    tot['dupacks'] += dup_total
    tot['dup_runs_ge3'] += run3
    allretx_duprun += [r for (_, _, _, r) in retx_events]
    detail.append((pp, len(pk), nretx, dup_total, run3, max_run,
                   [r for (_, _, _, r) in retx_events][:10]))

n = len(conns)
print(f"connections = {n}")
print(f"board retransmitted data segments = {tot['retx']}  ({tot['retx']/n:.2f}/conn)")
print(f"peer duplicate ACKs (ack not advancing) = {tot['dupacks']}  ({tot['dupacks']/n:.2f}/conn)")
print(f"dup-ACK runs of length >=3 (RFC 'dup-ACK triplets') = {tot['dup_runs_ge3']}")
print(f"retx with >=3 consecutive dup-ACKs immediately before = "
      f"{sum(1 for r in allretx_duprun if r>=3)} / {len(allretx_duprun)}")
print(f"retx with >=1 dup-ACK immediately before             = "
      f"{sum(1 for r in allretx_duprun if r>=1)} / {len(allretx_duprun)}")
print(f"retx with 0 dup-ACKs immediately before              = "
      f"{sum(1 for r in allretx_duprun if r==0)} / {len(allretx_duprun)}")
print()
print("per-conn (first 10): peer_port, pkts, retx, dupacks, runs>=3, max_run, dup_run_before_each_retx")
for row in detail[:10]:
    print("  ", row)
