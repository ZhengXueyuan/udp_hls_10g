#!/usr/bin/env python3
# a3_recon.py -- P7B A3 负对照轮: 逐回合对账 (板侧 SNAP 差分 + 对端 bytes)
#   口径: 差值一律 mod 2^32, 同时打印 raw a/b 与检出的回卷 k (b<a => k+1; k>1 无法从两点判定, 标 '*' 提示)。
#   ⛔ 只报读数, 不下 PASS/FAIL 裁定。
#   用法: python a3_recon.py <raw1.txt> [raw2.txt ...]
import re
import sys

MOD = 1 << 32
FCLK = 156.25e6


def parse(path):
    snaps = {}
    cur = None
    cur_tag = None
    events = []          # 文档顺序: ('snap', tag) / ('round', dict)
    for ln in open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'^SNAP_BEGIN (\S+) gen=(\d+)', ln)
        if m:
            cur = {}
            cur_tag = m.group(1)
            continue
        m = re.match(r'^SNAP_END (\S+)', ln)
        if m:
            if cur is not None:
                snaps[cur_tag] = cur
                events.append(('snap', cur_tag))
            cur = None
            continue
        m = re.match(r'^W(\d+)\s+(0x[0-9A-Fa-f]+)\s+\S+\s+(0x[0-9a-fA-F]+|\?)$', ln)
        if m and cur is not None:
            v = m.group(3)
            if v.startswith('0x'):
                cur[int(m.group(1))] = int(v, 16)
            continue
        m = re.match(r'^ROUND (\d+) bytes1=(\d+) \((\S+)\) bytes2=(\d+) \((\S+)\) \| '
                     r'conn1_ms=([\d.]+) rcv1_s=([\d.]+) gap_ms=([\d.]+) rcv2_s=([\d.]+) close=(\S+)', ln)
        if m:
            events.append(('round', {
                'bytes1': int(m.group(2)), 'st1': m.group(3),
                'bytes2': int(m.group(4)), 'st2': m.group(5), 'conn1_ms': float(m.group(6)),
                'rcv1_s': float(m.group(7)), 'gap_ms': float(m.group(8)), 'rcv2_s': float(m.group(9)),
                'close': m.group(10)}))
            continue
        m = re.match(r'^ROUND (\d+) CONNECT[12]_FAIL (.*)$', ln)
        if m:
            events.append(('round', {'fail': m.group(2)}))
    # ⚠️ a3_reconnect.py 每次调用都打 "ROUND 1" (--rounds 1) ⇒ 回合号按**出现顺序**编, 不采信行内数字。
    #    每行 ROUND 的前一个 snap = 该回合 pre, 后一个 snap = post (与 a3_round*.sh 的编排一致)。
    rounds = []
    for i, (kind, payload) in enumerate(events):
        if kind != 'round':
            continue
        pre = None
        post = None
        j = i - 1
        while j >= 0 and pre is None:
            if events[j][0] == 'snap':
                pre = events[j][1]
            j -= 1
        j = i + 1
        while j < len(events) and post is None:
            if events[j][0] == 'snap':
                post = events[j][1]
            j += 1
        rounds.append((pre, post, payload))
    return snaps, [t for k, t in events if k == 'snap'], rounds


def delta(a, b, name):
    """两点差分 mod 2^32; 返回 (raw_delta, k, warn)"""
    k = 1 if b < a else 0
    d = (b - a) % MOD
    warn = ''
    # 可疑性: 若 b < a 但 delta 明显小于"另一支"的尺度 —— 留给读的人; 这里只标 k>=1
    if k:
        warn = ''
    return d, k, warn


def show(pairs, label, words):
    print('%s' % label)
    for w in words:
        if w not in pairs[0] or w not in pairs[1]:
            continue
        a = pairs[0][w]
        b = pairs[1][w]
        d, k, _ = delta(a, b, w)
        extra = ''
        if w == 5 and d > 0:
            extra = '  dt_s≈%.4f' % (d / FCLK)
        if w == 20 and d > 0 and 5 in pairs[0] and 5 in pairs[1]:
            d5, _, _ = delta(pairs[0][5], pairs[1][5], 5)
            if d5 > 0:
                extra = '  fps≈%.1f' % (d / (d5 / FCLK))
        print('  W%-3s a=0x%08x b=0x%08x k=%d d=%-12d%s' % (w, a, b, k, d, extra))


def main():
    for path in sys.argv[1:]:
        snaps, order, rounds = parse(path)
        # 字表 = 该文件里出现过的全部字 (按出现顺序的数字序)
        wordset = sorted({w for s in snaps.values() for w in s})
        print('=' * 78)
        print('FILE %s   字表=%s' % (path, ' '.join('W%d' % w for w in wordset)))
        # 静默窗
        idle = [t for t in order if 'idle' in t]
        if len(idle) >= 2:
            show((snaps[idle[0]], snaps[idle[1]]), '静默窗 %s -> %s (无连接):' % (idle[0], idle[1]), wordset)
        for rn, (pre, post, r) in enumerate(rounds, 1):
            if 'fail' in r:
                print('回合 %d: 连接失败形态: %s (pre=%s post=%s)' % (rn, r['fail'], pre, post))
                continue
            print('回合 %d (close=%s): bytes1=%d (%s) bytes2=%d (%s) | conn1_ms=%.2f rcv1_s=%.3f gap_ms=%.2f rcv2_s=%.3f'
                  % (rn, r['close'], r['bytes1'], r['st1'], r['bytes2'], r['st2'],
                     r['conn1_ms'], r['rcv1_s'], r['gap_ms'], r['rcv2_s']))
            if pre and post and pre in snaps and post in snaps:
                show((snaps[pre], snaps[post]), '  %s -> %s:' % (pre, post), wordset)
        print()


if __name__ == '__main__':
    main()
