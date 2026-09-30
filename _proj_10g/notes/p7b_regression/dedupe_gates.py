# -*- coding: utf-8 -*-
# 把候选入口脚本按「它编译哪个 TB」去重；同 TB = 同一门（历史私有副本）。
# 只读。
import os
import re
import sys
from collections import defaultdict

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))

BAD_PARTS = {'.git', 'vivado_prj', '.runs', 'xsim.dir', '_mut_logs',
             'evidence', 'node_modules', '.Xil'}


def cands():
    for dp, dn, fn in os.walk(ROOT):
        dn[:] = [d for d in dn if d not in BAD_PARTS]
        for f in fn:
            if f.endswith(('.bat', '.sh')) and f.startswith('run'):
                yield os.path.relpath(os.path.join(dp, f), ROOT)\
                    .replace('/', '\\')


TB_RE = re.compile(r'(?:^|[\s\\/"])(tb_[A-Za-z0-9_]+\.v)\b', re.I)
SRC_RE = re.compile(r'([A-Za-z0-9_]+\.v)\b')

groups = defaultdict(list)
unresolved = []
for rel in sorted(set(cands())):
    p = os.path.join(ROOT, rel)
    try:
        t = open(p, encoding='latin-1', errors='replace').read()
    except Exception:
        continue
    tbs = sorted(set(m.lower() for m in TB_RE.findall(t)))
    if not tbs:
        unresolved.append(rel)
        continue
    key = '+'.join(tbs)
    groups[key].append(rel)

print('入口脚本(候选) : %d' % len(set(cands())))
print('可解析出 TB 的 : %d 个脚本 -> %d 组(去重后的"门")'
      % (sum(len(v) for v in groups.values()), len(groups)))
print('未解析出 TB    : %d' % len(unresolved))
print()
for k in sorted(groups, key=lambda x: (-len(groups[x]), x)):
    v = groups[k]
    print('%-46s x%-3d canon=%s' % (k, len(v), v[0]))
    for x in v[1:]:
        print('        ' + ' ' * 40 + 'dup: ' + x)
print()
print('--- 未解析出 TB 的脚本 ---')
for u in unresolved:
    print('  ' + u)
