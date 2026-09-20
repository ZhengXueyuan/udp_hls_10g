#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""在 sim/p5e_pre 内跑 canonical P5a 判据 (tools/gen_stim_p5_app.py check)，
对 P5e 前置实验的 A/B 两份落盘做"非干扰性"旁证。

做法: canonical check() 硬编码读 <simdir>/resp_p5_app.memh ⇒ 在 scratch 目录里
把它改名放好 (不动 sim/p5sim 的 canonical 产物)。

用法: python run_canon_check.py <resp.memh> <scratch-name>
"""
import io
import os
import shutil
import sys

D = os.path.dirname(os.path.abspath(__file__))
TOOLS = r"D:\repo\ECO\udp_hls_10g\tools"
sys.path.insert(0, TOOLS)


def main():
    resp, name = sys.argv[1], sys.argv[2]
    if not os.path.isabs(resp):
        resp = os.path.join(D, resp)
    scratch = os.path.join(D, name)
    os.makedirs(scratch, exist_ok=True)
    shutil.copyfile(resp, os.path.join(scratch, 'resp_p5_app.memh'))
    for extra in ('p5bad.memh', 'p5rx.memh'):
        src = os.path.join(D, extra)
        if os.path.exists(src):
            shutil.copyfile(src, os.path.join(scratch, extra))
    import gen_stim_p5_app as G
    print('=== canonical P5a checker on %s (as resp_p5_app.memh) ===' % resp)
    rc = G.check(scratch)
    print('=== %s: canonical check rc=%d ===' % (name, rc))
    return rc


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
