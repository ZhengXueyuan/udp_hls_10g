# -*- coding: utf-8 -*-
# 枚举本仓所有"门"入口脚本（run*.bat / run*.sh / 若干 lint 类入口），并归类。
# 只读，不写任何东西（除了 stdout）。
import io
import os
import re
import sys
from collections import Counter

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
ROOT = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(ROOT, '..', '..', '..'))

SKIP_PARTS = {'.git', 'vivado_prj', '.runs', 'xsim.dir', '_mut_logs',
              'node_modules', '.Xil'}
SKIP_SUFFIX = ('.runs',)

NAME_RE = re.compile(
    r'^(run\w*|lint\w*|chk\w*|dbg\w*|pre\w*|post\w*|t[0-9]\w*|g[0-9]\w*|'
    r'analyze_ooc|verify_domains|vd[0-9]|path_cells|idiom_\w+|fs_semantics|'
    r'implicit_gate\w*|abort|fin|len|multi|wnd|b2b|evfifo|findrop|reconn_\w+|'
    r'mech\w*|suite\w*|negctrl\w*|skew|torture|exp[0-9]|repro|ctr|pre)'
    r'\.(bat|sh)$')


def rel(p):
    return os.path.relpath(p, ROOT).replace('/', '\\')


rows = []
for dp, dn, fn in os.walk(ROOT):
    dn[:] = [d for d in dn if d not in SKIP_PARTS
             and not d.endswith(SKIP_SUFFIX)]
    for f in fn:
        if not f.endswith(('.bat', '.sh')):
            continue
        if f.startswith('run') or NAME_RE.match(f):
            rows.append(rel(os.path.join(dp, f)))

rows = sorted(set(rows))
print('候选入口脚本总数: %d' % len(rows))
c = Counter()
for r in rows:
    parts = r.split('\\')
    key = '\\'.join(parts[:2]) if len(parts) > 2 else r
    c[key] += 1
print('--- 按目录归类 ---')
for k, v in sorted(c.items()):
    print('  %-52s %d' % (k, v))
print('--- 全清单 ---')
for r in rows:
    print(r)
