#!/usr/bin/env python
"""一键回归: 全链 echo 闭环 (GMII->MAC->RX->echo->TX->MAC->GMII) -> 回发帧验证。

用法: /c/Users/zhxue/anaconda3/python.exe tools/run_echo_tb.py
"""
import os
import sys
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "sim", "echosim")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_echo


def main():
    frames = gen_stim_echo.generate(SIM)
    print('frames=%d' % len(frames))
    bat = os.path.join(SIM, "run_tb_echo.bat")
    r = subprocess.run(["cmd", "/c", bat], cwd=SIM,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("---- xsim run failed ----")
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        sys.exit(1)
    ok, errs = gen_stim_echo.check(SIM)
    if ok:
        print("== ALL PASS ==")
    else:
        print("== FAILED ==")
        for e in errs[:12]:
            print('  ' + e)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
