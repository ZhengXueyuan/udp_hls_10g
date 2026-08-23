#!/usr/bin/env python
"""比对 resp_tx.memh 与 expected_tx.memh: 从首个 en=1 对齐, 逐拍全等,
期望结束后的尾部必须全 idle; 统计行 (frames/abort) 全等。"""
import sys
import os


def load_trace(path):
    lines, stats = [], None
    with open(path) as fh:
        for ln in fh:
            ln = ln.strip().upper()
            if not ln:
                continue
            if ln.startswith("STATS"):
                stats = tuple(int(x) for x in ln.split()[1:3])
                continue
            p = ln.split()
            lines.append((int(p[0]), p[1]))
    return lines, stats


def first_en(trace):
    for i, (en, _) in enumerate(trace):
        if en == 1:
            return i
    return None


def check(resp_path, exp_path, stats_path, tag="tx"):
    resp, rstats = load_trace(resp_path)
    exp, _ = load_trace(exp_path)
    with open(stats_path) as fh:
        ef, ea = (int(x) for x in fh.read().split())
    ri, ei = first_en(resp), first_en(exp)
    if ri is None or ei is None:
        print("[%s] FAIL: 无 en=1 (resp %s exp %s)" % (tag, ri, ei))
        return False
    a, b = resp[ri:], exp[ei:]
    if len(a) < len(b):
        print("[%s] FAIL: resp 比期望短 %d vs %d" % (tag, len(a), len(b)))
        return False
    for i in range(len(b)):
        if a[i] != b[i]:
            print("[%s] FAIL @%d: resp %s exp %s" % (tag, i, a[i], b[i]))
            for j in range(max(0, i - 3), min(len(a), i + 4)):
                mark = '>' if j == i else ' '
                exp_s = str(b[j]) if j < len(b) else '?'
                print("   %s%4d: resp %s%s" % (mark, j, a[j], '   EXP ' + exp_s if a[j] != (b[j] if j < len(b) else None) else ''))
            return False
    tail = a[len(b):]
    if any(en for en, _ in tail):
        print("[%s] FAIL: 期望结束后仍有 en=1 (%d 拍)" % (tag, len(tail)))
        return False
    if rstats != (ef, ea):
        print("[%s] FAIL: stats resp %s exp %s" % (tag, rstats, (ef, ea)))
        return False
    print("[%s] PASS: %d 拍比对一致, stats %s" % (tag, len(b), rstats))
    return True


if __name__ == '__main__':
    sim = sys.argv[1] if len(sys.argv) > 1 else 'sim'
    ok = check(os.path.join(sim, 'resp_tx.memh'),
               os.path.join(sim, 'expected_tx.memh'),
               os.path.join(sim, 'expected_tx_stats.txt'))
    sys.exit(0 if ok else 1)
