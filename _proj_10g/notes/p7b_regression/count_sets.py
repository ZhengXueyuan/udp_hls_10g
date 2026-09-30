# -*- coding: utf-8 -*-
# 试算几种"门集合"定义下的计数，找出哪种接近交接件说的 76。
import os
import re
import sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))

BAD_PARTS = {'.git', 'vivado_prj', '.runs', 'xsim.dir', '_mut_logs'}
BAD_SUB = ('evidence', 'scratch', 'neg', 'mut', 'old', 'prv', 'iso',
           'priv', 'spot', 'bad5', 'f2_scratch', 'pre_migration')


def collect(root_sub, pat):
    out = []
    for dp, dn, fn in os.walk(os.path.join(ROOT, root_sub)):
        dn[:] = [d for d in dn if d not in BAD_PARTS]
        for f in fn:
            if re.match(pat, f):
                out.append(os.path.relpath(os.path.join(dp, f), ROOT)
                           .replace('/', '\\'))
    return sorted(set(out))


CAND = {
    'A: sim/**/run_tb_*.bat（剔 evidence/scratch/neg/mut/prv）':
        collect('sim', r'run_tb.*\.bat$'),
    'B: A ∪ sim/**/run_*.sh':
        collect('sim', r'run_.*\.(bat|sh)$'),
    'C: B ∪ _proj_10g/**/sim/run_*.bat':
        collect('sim', r'run_.*\.(bat|sh)$')
        + collect('_proj_10g', r'run_.*\.bat$'),
}
for k, v in CAND.items():
    print('%-52s %d' % (k, len(v)))
    for x in v:
        print('      ' + x)
    print()
