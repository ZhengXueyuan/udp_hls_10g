# -*- coding: utf-8 -*-
"""对每份门日志抽"判据行"。EXIT=0 但抽不到判据行的 ⇒ 疑似哑门(类型②)。"""
import io
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
HERE = os.path.dirname(os.path.abspath(__file__))
LOGDIR = os.path.join(HERE, 'logs')

PAT = re.compile(
    r'ALL_OK|PASS_ALL|ALL \d+ GROUPS PASS|VERDICT\s*=\s*\w+|'
    r'GATE:\s*(OK|FAIL)|GATE OK|FAIL\b|MISMATCH|FAIL:|'
    r'\d+\s*(checks|项)\D{0,8}(0|fail)|errs=|PASS\b|OK\b', re.I)


def tail_lines(p, n=40):
    try:
        t = io.open(p, encoding='utf-8', errors='replace').read()
    except Exception:
        return []
    t = t.replace('\r', '')
    return [l for l in t.split('\n') if l.strip()][-n:]


rows = []
for f in sorted(os.listdir(LOGDIR)):
    if not f.endswith('.log'):
        continue
    p = os.path.join(LOGDIR, f)
    lines = tail_lines(p)
    body = '\n'.join(lines)
    m = re.search(r'runner: EXIT=(-?\d+)\s+([\d.]+)s', body)
    rc = m.group(1) if m else '?'
    secs = m.group(2) if m else '?'
    # 去掉我自己的 runner 头/尾，只看门自己的输出
    gate = [l for l in lines
            if not l.startswith('#') and 'runner: EXIT' not in l]
    hits = [l.strip() for l in gate if PAT.search(l)]
    rows.append((f[:-4], rc, secs, len(hits), (hits[-1][:96] if hits else '')))

print('%-24s %-6s %-8s %-3s %s' % ('gate', 'EXIT', 'secs', 'n', 'last hit'))
print('-' * 120)
for r in rows:
    print('%-24s %-6s %-8s %-3d %s' % (r[0], r[1], r[2], r[3], r[4]))

print()
print('--- EXIT=0 但判据行命中数 = 0（疑似哑门/只打 banner）---')
for r in rows:
    if r[1] == '0' and r[3] == 0:
        print('  %-24s secs=%s' % (r[0], r[2]))
