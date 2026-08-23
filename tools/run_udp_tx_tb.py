#!/usr/bin/env python
"""一键回归: 生成刺激 -> xsim 双模式 (csum_en 1/0) -> GMII 帧解码验证。

用法: /c/Users/zhxue/anaconda3/python.exe tools/run_udp_tx_tb.py
"""
import os
import sys
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "sim", "txsim")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_udp_tx


def main():
    frames = gen_stim_udp_tx.generate(SIM)
    print('frames=%d' % len(frames))
    bat = os.path.join(SIM, "run_tb_udp_tx.bat")
    r = subprocess.run(["cmd", "/c", bat], cwd=SIM,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("---- xsim run failed ----")
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        sys.exit(1)
    ok = True
    for csum_en, tag in ((True, 'csum1'), (False, 'csum0')):
        o, errs = gen_stim_udp_tx.check(SIM, csum_en)
        if o:
            print('%s: OK (%d frames)' % (tag, len(frames)))
        else:
            ok = False
            print('%s: FAIL' % tag)
            for e in errs[:10]:
                print('  ' + e)
    print("== ALL PASS ==" if ok else "== FAILED ==")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
