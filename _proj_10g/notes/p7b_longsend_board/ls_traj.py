# ls_traj.py -- P7B-LONGSEND **长流**轨迹/回卷读数器
#   口径: 每对相邻快照点 = 一个区间; dt = ΔW5/156.25e6; 速率 = ΔW51*8/dt (ΔW51 mod 2^32, 记 raw 与 k);
#         P = ΔW43/ΔW20; 线占空 = 193/P。
#   ⚠️ 区间必须 < 3.66 s (否则 W51 可能跨 2 次回卷而不可判) —— 脚本对 dt > 3.0 s 的区间**打红旗**。
#   回卷判定: k51 = 本区间内 W51 回卷次数; 逐区间统计 k=0 / k>=1 两组的速率/ΔW55/ΔW23 分布。
import re, sys

WRAP = 2**32
TB = 156.25e6
WANT = (5, 43, 20, 51, 15, 55, 23, 52, 21, 41, 42, 45, 59, 60, 14, 57)

def parse(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    snaps = []; cur = None; tstamp = {}
    for line in txt.splitlines():
        m = re.match(r'^LF_SNAP_T (\S+) (\d+)$', line)
        if m: tstamp[int(m.group(2))] = float(m.group(1)); continue
        m = re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', line)
        if m:
            tag = m.group(1)
            idx = int(tag.rsplit('_s', 1)[1]) if re.match(r'^.*_s\d+$', tag) else None
            cur = {'tag': tag, 'gen': int(m.group(2)), 'idx': idx, 'w': {}, 't': tstamp.get(idx)}
            snaps.append(cur); continue
        m = re.match(r'^W(\d+)\s+\S+\s+(\S+)\s+(0x[0-9a-fA-F]+)', line)
        if m and cur is not None: cur['w'][int(m.group(1))] = int(m.group(3), 16)
        if line.startswith('SNAP_END'): cur = None
    return snaps, txt

def dd(a, b):
    x = b - a; k = 0
    if x < 0: x += WRAP; k = 1
    return x, k

if __name__ == '__main__':
    path = sys.argv[1]
    snaps, txt = parse(path)
    pts = [s for s in snaps if s['idx'] is not None and 51 in s['w']]
    pts.sort(key=lambda s: s['idx'])
    print('# points=%d  (first=%s last=%s)' % (len(pts), pts[0]['tag'], pts[-1]['tag']))
    # 找流窗: W51 严格递增的最长连续段 (允许 1 次 2^32 回卷)
    rows = []
    kcum51 = 0
    for i in range(len(pts) - 1):
        A, B = pts[i], pts[i + 1]
        d51, k51 = dd(A['w'][51], B['w'][51])
        d5, k5 = dd(A['w'][5], B['w'][5])
        if d5 == 0: continue
        dt = d5 / TB
        d43, _ = dd(A['w'][43], B['w'][43]) if 43 in A['w'] and 43 in B['w'] else (0, 0)
        d20, _ = dd(A['w'][20], B['w'][20]) if 20 in A['w'] and 20 in B['w'] else (0, 0)
        d15, k15 = dd(A['w'][15], B['w'][15]) if 15 in A['w'] and 15 in B['w'] else (0, 0)
        d55, _ = dd(A['w'][55], B['w'][55]) if 55 in A['w'] and 55 in B['w'] else (0, 0)
        d23, _ = dd(A['w'][23], B['w'][23]) if 23 in A['w'] and 23 in B['w'] else (0, 0)
        kcum51 += k51
        rows.append(dict(i=i, tA=A['t'], tB=B['t'], dt=dt, d51=d51, k51=k51, kcum=kcum51,
                         rate=d51 * 8.0 / dt / 1e9 if dt else 0, d43=d43, d20=d20,
                         P=(d43 / d20 if d20 else 0), d15=d15, k15=k15, d55=d55, d23=d23,
                         w51A=A['w'][51], w51B=B['w'][51]))
    print('# idx  tA            dt_ms   dW51        k  kcum  rate_Gbps   P        duty%   dW15        dW55 dW23  red_rate')
    for r in rows:
        flag = ' ⚠️DT>3s' if r['dt'] > 3.0 else ''
        print('%4d %14.6f %7.1f %12d %d %5d  %9.4f  %9.2f %6.1f  %12d %4d %4d  %.7f%s' %
              (r['i'], r['tA'], r['dt'] * 1e3, r['d51'], r['k51'], r['kcum'], r['rate'], r['P'],
               193.0 / r['P'] if r['P'] else 0, r['d15'], r['d55'], r['d23'],
               (r['d15'] / r['d51']) if r['d51'] else 1.0, flag))
    # 分组统计: 含回卷 vs 不含
    inb = [r for r in rows if r['d51'] > 0]
    g1 = [r for r in inb if r['k51'] >= 1]
    g0 = [r for r in inb if r['k51'] == 0]
    print('# ---- 分组 (仅 dW51>0 的区间) ----')
    for name, g in (('k=0', g0), ('k>=1', g1)):
        if not g: print('# %s: n=0' % name); continue
        rs = sorted(r['rate'] for r in g)
        print('# %s: n=%d rate min=%.4f med=%.4f max=%.4f | sum dW55=%d sum dW23=%d | duty med=%.1f%%' %
              (name, len(g), rs[0], rs[len(rs) // 2], rs[-1],
               sum(r['d55'] for r in g), sum(r['d23'] for r in g),
               193.0 / sorted(r['P'] for r in g)[len(g) // 2]))
