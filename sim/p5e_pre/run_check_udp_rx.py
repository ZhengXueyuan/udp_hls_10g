#!/usr/bin/env python
"""P5e 实验1-2: 调用 gen_stim_udp_rx.py 里从未被任何 bat 调用的 check()。
用法: python run_check_udp_rx.py <simdir>
判据: 三模式 (nostall/stall/hard) 的 resp_udp_rx*.memh 逐行 == 周期精确参考模型。
退出码 = 0 全 OK, 1 任一 MISMATCH。
"""
import os
import sys

TOOLS = r"D:\repo\ECO\udp_hls_10g\tools"
sys.path.insert(0, TOOLS)

import gen_stim_udp_rx as G  # noqa: E402

simdir = sys.argv[1] if len(sys.argv) > 1 else r"D:\repo\ECO\udp_hls_10g\sim\rxsim"
bad = 0
for mode in ('nostall', 'stall', 'hard'):
    ok = G.check(simdir, mode)
    print('CHECK %-8s -> %s' % (mode, 'OK' if ok else 'MISMATCH'))
    if not ok:
        bad += 1
print('SUMMARY: %d/3 mode(s) OK' % (3 - bad))
sys.exit(1 if bad else 0)
