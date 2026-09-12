#!/usr/bin/env python
"""P4b-7 板测 SYN 交换扫描: pcapng -> 帧摘要 (TCP flags/seq/ack, ICMP, UDP)"""
import struct
import sys

fn = sys.argv[1] if len(sys.argv) > 1 else 'p4b7_syn.pcapng'
data = open(fn, 'rb').read()
frames = []
i = 0
while i + 12 <= len(data):
    btype = struct.unpack('<I', data[i:i + 4])[0]
    blen = struct.unpack('<I', data[i + 4:i + 8])[0]
    if blen < 12 or i + blen > len(data):
        break
    if btype == 6:
        body = data[i + 8:i + blen - 4]
        ifid, tsh, tsl, caplen, origlen = struct.unpack('<IIIII', body[:20])
        frames.append(((tsh * 2**32 + tsl) / 1e6, body[20:20 + caplen]))
    i += blen
print('frames:', len(frames))
rows = []
for ts, p in frames:
    if len(p) < 54:
        continue
    if p[12:14] != b'\x08\x00':
        rows.append((ts, 'eth=%s len=%d' % (p[12:14].hex(), len(p))))
        continue
    ip = p[14:]
    ihl = (ip[0] & 0xf) * 4
    proto = ip[9]
    src = '%d.%d.%d.%d' % tuple(ip[12:16])
    dst = '%d.%d.%d.%d' % tuple(ip[16:20])
    if proto == 6:
        t = ip[ihl:]
        sport, dport = struct.unpack('!HH', t[0:4])
        flags = t[13]
        seq, ack = struct.unpack('!II', t[4:12])
        plen = len(ip) - ihl - ((t[12] >> 4) * 4)
        rows.append((ts, 'TCP %s:%d -> %s:%d fl=0x%02x seq=%u ack=%u plen=%d'
                     % (src, sport, dst, dport, flags, seq, ack, plen)))
    elif proto == 1:
        rows.append((ts, 'ICMP %s -> %s type=%d' % (src, dst, ip[ihl])))
    elif proto == 17:
        t = ip[ihl:]
        rows.append((ts, 'UDP %s:%d -> %s:%d' % (src,
                     struct.unpack('!H', t[0:2])[0], dst,
                     struct.unpack('!H', t[2:4])[0])))
# echo seq hole detection (FPGA->PC data frames, sport 8080)
echo_seq = None
holes = 0
for ts, r in rows:
    if r.startswith('TCP 192.168.100.2:8080') and 'plen=' in r and r.split('plen=')[1] != '0':
        s = int(r.split('seq=')[1].split(' ')[0])
        p = int(r.split('plen=')[1])
        if echo_seq is not None and s != echo_seq:
            print('ECHO HOLE: seq %u != expected %u (gap %d) at t=%.3f'
                  % (s, echo_seq, s - echo_seq, ts))
            holes += 1
        echo_seq = s + p
print('echo holes:', holes)
# control frames + head/tail
for ts, r in rows:
    if 'fl=0x0' in r and 'RST' not in r:
        r += ' RST'
    if 'fl=0x01' in r or 'fl=0x04' in r or 'fl=0x14' in r or 'RST' in r:
        print('CTRL t=%.3f %s' % (ts, r))
print('--- head 5 ---')
for ts, r in rows[:5]:
    print('t=%.3f %s' % (ts, r))
print('--- tail 12 ---')
for ts, r in rows[-12:]:
    print('t=%.3f %s' % (ts, r))
