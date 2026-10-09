#!/usr/bin/env python3
# whole_run.py -- P7B-A7 板级轮: **整链 (pre -> post) 跨仪器对账** 一次成型
#   三个独立仪器: 板侧计数器 (W*) / 对端 NIC 硬件计数 (GEOM_NOPCAP) / sink 自报 (SINK_SUM)
#   纪律: 全部 mod 2^32, 记 raw 与 k; k 由**链条单调 unwrap** 定 (相邻点间隔 < 1 s << 27.487 s)。
import re, sys, json
FCLK = 156.25e6
MOD = 1 << 32

def parse(path):
    snaps = []
    cur = None; curtag = None
    for ln in open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', ln)
        if m: cur = {}; curtag = m.group(1); continue
        m = re.match(r'^SNAP_END (\S+)', ln)
        if m:
            snaps.append((curtag, cur)); cur = None; continue
        m = re.match(r'^W(\d+)\s+(0x[0-9A-Fa-f]+)\s+\S+\s+(0x[0-9a-fA-F]+|\?)$', ln)
        if m and cur is not None:
            v = m.group(3)
            if v.startswith('0x'): cur[int(m.group(1))] = int(v, 16)
    return snaps

def whole(path, words):
    snaps = parse(path)
    a, b = snaps[0], snaps[-1]
    out = {}
    for w in words:
        last = None; k = 0; seen_any = False
        for (_t, d) in snaps:
            if w not in d: continue
            v = d[w]
            if last is not None and v < last: k += 1
            last = v; seen_any = True
        if not seen_any: continue
        ra, rb = a[1].get(w), b[1].get(w)
        if ra is None or rb is None: continue
        rawd = (rb - ra) % MOD
        out['W%d' % w] = {'raw_a': hex(ra), 'raw_b': hex(rb), 'raw_delta': rawd,
                          'k': k, 'mono': rawd + k * MOD}
    return out

def getline(path, pat):
    for ln in open(path, encoding='utf-8', errors='replace'):
        if re.match(pat, ln): return ln.strip()
    return None

if __name__ == '__main__':
    for path in sys.argv[1:]:
        wr = whole(path, [5, 20, 43, 51, 15, 65, 63, 64, 55, 45, 28, 21, 41, 42, 0, 1])
        print('### %s' % path)
        for k in ('W5', 'W20', 'W43', 'W51', 'W15', 'W65', 'W63', 'W64', 'W55', 'W45', 'W28', 'W21', 'W41', 'W42', 'W0', 'W1'):
            if k in wr:
                v = wr[k]
                print('  %-4s raw %s -> %s  rawd=%d k=%d mono=%d' % (k, v['raw_a'], v['raw_b'], v['raw_delta'], v['k'], v['mono']))
        ln = getline(path, r'^GEOM_NOPCAP')
        print('  NIC :', ln)
        ln = getline(path, r'^SINK_SUM')
        print('  SINK:', ln)
        # --- 对账 ---
        if 'W20' in wr and ln:
            m = re.search(r'd_pkts=(\d+)', getline(path, r'^GEOM_NOPCAP') or '')
            if m:
                nic = int(m.group(1))
                print('  RECON ΔW20(mono)=%d vs NIC Δpkts=%d  diff=%d' % (wr['W20']['mono'], nic, nic - wr['W20']['mono']))
        sm = getline(path, r'^SINK_SUM')
        if sm and 'W51' in wr:
            mb = re.search(r'bytes=(\d+)', sm)
            if mb:
                print('  RECON ΔW51(mono)=%d vs SINK bytes=%s  diff=%d' % (wr['W51']['mono'], mb.group(1), wr['W51']['mono'] - int(mb.group(1))))
        nm = getline(path, r'^GEOM_NOPCAP')
        if nm and 'W51' in wr:
            mbb = re.search(r'd_bytes=(\d+)', nm)
            if mbb:
                print('  RECON ΔW51(mono)=%d vs NIC Δbytes=%s (含hdr/FCS/重复) diff=%d' % (wr['W51']['mono'], mbb.group(1), wr['W51']['mono'] - int(mbb.group(1))))
