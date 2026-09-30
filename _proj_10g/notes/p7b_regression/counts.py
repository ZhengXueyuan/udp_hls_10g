# -*- coding: utf-8 -*-
import os
import sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
R = r'D:\repo\XCKU5PMini\udp_hls_10g'
SKIP = {'.git', 'vivado_prj', '.runs', 'xsim.dir', '_mut_logs',
        'node_modules', '.Xil'}
cand = []
for dp, dn, fn in os.walk(R):
    dn[:] = [d for d in dn if d not in SKIP]
    for f in fn:
        if f.endswith(('.bat', '.sh')) and f.startswith('run'):
            cand.append(os.path.relpath(os.path.join(dp, f), R)
                        .replace(os.sep, '/'))
cand = sorted(set(cand))
print('run* 入口（剔 .git/vivado_prj/.runs/xsim.dir/_mut_logs）: %d' % len(cand))


def cnt(pred):
    return sum(1 for c in cand if pred(c))


print('  run_program_*  (硬件烧录)          : %d'
      % cnt(lambda c: 'run_program' in c))
print('  run_build_*/run_syn*/run_hls*      : %d'
      % cnt(lambda c: any(k in c for k in
                          ('run_build', 'run_syn', 'run_hls'))))
print('  route_check/ooc/timing/readback/.. : %d'
      % cnt(lambda c: any(k in c for k in
                          ('route_check', 'run_ooc', 'run_timing',
                           'extra_reports', 'readback', 'lic_deny',
                           'xdc_probe', 'run_link_check', 'run_t_exec',
                           'run_probe_drp', 'run_probe_lat'))))
print('  *_scratch* 脚手架                  : %d'
      % cnt(lambda c: 'scratch' in c))
print('  变异/负对照(neg/mut/old/prv/iso/..): %d'
      % cnt(lambda c: any(k in c.lower() for k in
                          ('neg', '_mut', 'mut', '_old', 'prv', 'p4spot',
                           'p4iso', 'bad5', 'review_scratch'))))
print('  sim/p4gates/evidence/** 归档副本   : %d'
      % cnt(lambda c: 'evidence' in c))
print('  probe/diag 探针脚本                : %d'
      % cnt(lambda c: 'probe' in c or 'diag' in c))
print('  跑 runme.bat (Vivado 工程自动生成) : %d'
      % cnt(lambda c: c.endswith('runme.bat')))
print('  notes/p7b_gate4* (别的 agent)      : %d'
      % cnt(lambda c: 'p7b_gate4' in c))
