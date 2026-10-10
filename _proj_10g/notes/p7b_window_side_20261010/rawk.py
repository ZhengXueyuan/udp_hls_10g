#!/usr/bin/env python3
# rawk.py -- 全窗口 (首点->末点) 逐字 raw/k 表: W5 时基 / W20 帧 / W63/W64/W65/W66
#   规则: 32 位计数器; 先按快照链单调 unwrap 数回卷次数 k, 再报 raw_a/raw_b/raw_delta/k/mono_delta
import re, sys
MOD = 1 << 32
WORDS = [5, 20, 43, 51, 15, 63, 64, 65, 66]

def parse(path):
    snaps = []; cur = None
    for ln in open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', ln)
        if m: cur = {}; continue
        if re.match(r'^SNAP_END ', ln): snaps.append(cur); cur = None; continue
        m = re.match(r'^W(\d+)\s+(0x[0-9A-Fa-f]+)\s+\S+\s+(0x[0-9a-fA-F]+|\?)$', ln)
        if m and cur is not None:
            v = m.group(3)
            if v.startswith('0x'): cur[int(m.group(1))] = int(v, 16)
    return snaps

for path in sys.argv[1:]:
    tag = path.split('/')[-1][:-4]
    snaps = parse(path)
    # 每个字的链 (仅用含该字的点)
    out = []
    for w in WORDS:
        chain = [s[w] for s in snaps if w in s]
        if len(chain) < 2: out.append('W%d: n/a' % w); continue
        k = 0; last = None; mono = 0
        for v in chain:
            if last is not None and v < last: k += 1
            last = v
        raw_delta = (chain[-1] - chain[0]) % MOD
        mono = raw_delta + k * MOD if (k > 0 or chain[-1] >= chain[0]) else None
        out.append('W%d: A=%d B=%d raw_delta=%d k=%d mono=%d' % (w, chain[0], chain[-1], raw_delta, k, raw_delta + k * MOD))
    print('== %s (npts=%d)' % (tag, len(snaps)))
    for o in out: print('   ' + o)
