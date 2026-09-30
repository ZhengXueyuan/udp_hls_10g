# -*- coding: utf-8 -*-
"""在 A/B 基线 worktree 上跑指定门（默认 02d51ed）。只读原仓，写 ab/ 目录。"""
import io
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
HERE = os.path.dirname(os.path.abspath(__file__))
AB = os.path.join(HERE, 'ab')
WT = r'D:\repo\XCKU5PMini\_ab_p7b_02d51ed'
if len(sys.argv) > 1 and sys.argv[1].startswith('--wt='):
    WT = sys.argv[1][5:]

GATES = [
    ('AB_OLD_p3_tcp_chain', r'sim\p3sim\run_tb_tcp_chain.bat', [], 600),
    ('AB_OLD_p4_chain_active', r'sim\p4sim\run_tb_p4_chain_active.bat', [], 900),
    ('AB_OLD_p5d_mech', r'sim\p5d_multi\p5dmech\run_mech.bat', [], 900),
    ('AB_OLD_snapcdc24_p6e', r'sim\snapcdc\review24\p6e\run.bat', [], 600),
    ('AB_OLD_p6e_pcie_cnt', r'sim\p6e_pcie\run_tb_p6e_pcie_counters.bat', [], 600),
    ('AB_OLD_f4_regress', r'sim\f4sim\run_tb_mac_f4regress.bat', [], 600),
    ('AB_OLD_run_tb_tx', r'sim\run_tb_tx.bat', [], 600),
    ('AB_OLD_snapcdc_skew', r'sim\snapcdc\review\run_skew.bat', [], 600),
    ('AB_OLD_p4_probe', r'sim\p4sim\run_probe.bat', [], 600),
    ('AB_OLD_p4_hlsprobe', r'sim\p4sim_hlsprobe\run_hls_udp_probe.bat', [], 900),
    ('AB_OLD_d2_mechf', r'sim\p5d_multi\p5dmech\run_mechf.bat', [], 900),
]

only = set(a for a in sys.argv[1:] if not a.startswith('--wt='))
for name, bat, args, tmo in GATES:
    if only and name not in only:
        continue
    p = os.path.join(WT, bat)
    lp = os.path.join(AB, name + '.log')
    t0 = time.time()
    if not os.path.exists(p):
        print('%-28s MISSING %s' % (name, bat))
        continue
    with io.open(lp, 'w', encoding='utf-8', errors='replace') as f:
        f.write('# A/B baseline worktree: %s\n# bat: %s\n# started: %s\n\n'
                % (WT, bat, time.strftime('%Y-%m-%d %H:%M:%S')))
        f.flush()
        try:
            r = subprocess.run(['cmd', '/c', p] + list(args), cwd=WT,
                               stdout=f, stderr=subprocess.STDOUT, timeout=tmo)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc = -999
    print('%-28s EXIT=%-6s %6.1fs' % (name, rc, time.time() - t0))
    sys.stdout.flush()
