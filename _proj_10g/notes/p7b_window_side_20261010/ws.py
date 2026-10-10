#!/usr/bin/env python3
# ws.py -- P7b 窗口侧判别轮: 解析 lf_dl.sh 自带的 ss 采样日志 (对端 sink socket 的通告窗见证)
#   输入: runs/<TAG>_ss.log  (每行 "SS_T <ts> <ss -tinma 输出, | 分行>")
#   输出: 每跑一行 —— 流内 (ESTAB) 样本数 + rcv_space / rcv_ssthresh / Recv-Q / skmem.r 的
#         min/med/max + wscale 字段是否出现 + snd_wnd + minrtt
#   ⚠️ 通告窗 = min(free_space, rcv_ssthresh) 的上界由 rcv_ssthresh 决定;
#      rcv_space = 内核自适应的"最大窗" 上限; 两者都报, 不合成一个数。
import re, sys, statistics as st

def parse(path):
    rows = []
    for ln in open(path, encoding='utf-8', errors='replace'):
        if not ln.startswith('SS_T '): continue
        ts = float(ln.split()[1])
        body = ln.split(' ', 2)[2] if len(ln.split(' ', 2)) > 2 else ''
        if 'ESTAB' not in body: continue
        head = body; info = body
        d = {'ts': ts}
        m = re.search(r'ESTAB\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)', head)
        if m:
            d['recvq'] = int(m.group(1)); d['sendq'] = int(m.group(2))
            d['local'] = m.group(3); d['peer'] = m.group(4)
        for key in ('rcv_space', 'rcv_ssthresh', 'snd_wnd', 'minrtt', 'rtt', 'rcv_rtt', 'rcv_ooopack',
                    'cwnd', 'bytes_received', 'segs_in', 'data_segs_in'):
            m = re.search(key + r':([0-9.]+)(?:/[0-9.]+)?', info)
            if m: d[key] = float(m.group(1))
        m = re.search(r'skmem:\(r(\d+),rb(\d+),', info)
        if m: d['sk_r'] = int(m.group(1)); d['sk_rb'] = int(m.group(2))
        m = re.search(r'wscale:([0-9]+),([0-9]+)', info)
        d['wscale'] = (int(m.group(1)), int(m.group(2))) if m else None
        rows.append(d)
    return rows

def stats(vals):
    vals = [v for v in vals if v is not None]
    if not vals: return None
    return dict(n=len(vals), min=min(vals), med=st.median(vals), max=max(vals))

for path in sys.argv[1:]:
    tag = path.split('/')[-1].replace('_ss.log', '')
    rows = parse(path)
    if not rows:
        print('%-14s n_estab=0  (无流内样本)' % tag); continue
    rs = stats([r.get('rcv_space') for r in rows])
    ss = stats([r.get('rcv_ssthresh') for r in rows])
    rq = stats([r.get('recvq') for r in rows])
    skr = stats([r.get('sk_r') for r in rows])
    rb = rows[0].get('sk_rb')
    sw = stats([r.get('snd_wnd') for r in rows])
    mr = stats([r.get('minrtt') for r in rows])
    ws = set(str(r.get('wscale')) for r in rows)
    oo = stats([r.get('rcv_ooopack') for r in rows])
    dur = rows[-1]['ts'] - rows[0]['ts']
    print('%s  n_estab=%d span=%.2fs local=%s peer=%s' % (tag, len(rows), dur, rows[0].get('local'), rows[0].get('peer')))
    print('   rcv_space    n=%s min=%s med=%s max=%s' % (rs['n'], rs['min'], rs['med'], rs['max']))
    print('   rcv_ssthresh n=%s min=%s med=%s max=%s' % (ss['n'], ss['min'], ss['med'], ss['max']))
    print('   Recv-Q       min=%s med=%s max=%s   skmem.r  min=%s med=%s max=%s   skmem.rb=%s' % (
        rq['min'], rq['med'], rq['max'], skr['min'], skr['med'], skr['max'], rb))
    print('   snd_wnd(板->对端通告) min=%s med=%s max=%s   minrtt min=%s med=%s max=%s' % (
        sw['min'], sw['med'], sw['max'], mr['min'], mr['med'], mr['max']))
    print('   wscale 取值集合=%s   rcv_ooopack min=%s max=%s' % (ws, oo['min'] if oo else None, oo['max'] if oo else None))
    # 逐样本 "上界窗" = min(rcv_ssthresh, sk_rb - sk_r) (无 wscale 时直接可比 61440)
    ub = []
    for r in rows:
        if 'rcv_ssthresh' in r and 'sk_r' in r and r.get('sk_rb'):
            ub.append(min(r['rcv_ssthresh'], r['sk_rb'] - r['sk_r']))
    if ub:
        print('   窗上界 min(rcv_ssthresh, free) : min=%d med=%d max=%d   >61440 的样本=%d/%d' % (
            min(ub), int(st.median(ub)), max(ub), sum(1 for v in ub if v > 61440), len(ub)))
