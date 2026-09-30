# -*- coding: utf-8 -*-
# 静态扫"哑门": 入口 .bat/.sh 的**最后一条有效命令**是否会把失败传出去。
# 只读。
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
sys.path.insert(0, HERE)
import importlib.util
spec = importlib.util.spec_from_file_location(
    'rag', os.path.join(HERE, 'run_all_gates.py'))
rag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rag)

VERDICT_HINT = re.compile(
    r'ALL_OK|PASS|FAIL|MISMATCH|OK\b|checks|ERROR|SUCCESS|DONE', re.I)

for g in rag.G:
    name, bat = g[0], g[1]
    p = os.path.join(ROOT, bat)
    if not os.path.exists(p):
        print('%-24s MISSING %s' % (name, bat))
        continue
    lines = [l.rstrip('\r\n') for l in
             io.open(p, encoding='latin-1', errors='replace')]
    # 最后一条非注释、非空、非 goto/label 的行
    eff = [l for l in lines
           if l.strip() and not l.strip().lower().startswith('rem')
           and not l.strip().startswith(':')]
    last = eff[-1] if eff else '(empty)'
    tail = '\n'.join(lines[-6:])
    mute = []
    if re.match(r'^\s*exit\s*/b\s+0\s*$', last, re.I) or \
       re.match(r'^\s*exit\s+0\s*$', last, re.I):
        mute.append('LAST-EXIT-0')
    if re.search(r'^type\s+\S*\.log', last, re.I):
        mute.append('LAST-TYPE-LOG')
    if not re.search(r'exit\s*/\s*b\s+\d|exit\s+\d|errorlevel', tail, re.I):
        mute.append('NO-EXITCODE-IN-TAIL')
    print('%-24s %-58s %s' % (name, bat, ','.join(mute) if mute else 'ok'))
    if mute:
        for l in lines[-4:]:
            print('        | ' + l)
