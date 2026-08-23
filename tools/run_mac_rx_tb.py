#!/usr/bin/env python
"""一键回归: 生成刺激 -> xsim 三模式 (无背压 / 周期抖动 / 硬停) -> 逐字节比对。

用法: /c/Users/zhxue/anaconda3/python.exe tools/run_mac_rx_tb.py
"""
import os
import sys
import subprocess
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "sim")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_mac
import parse_mac_rx


def run_tb(arg, tag):
    bat = os.path.join(SIM, "run_tb.bat")
    r = subprocess.run(["cmd", "/c", bat, arg], cwd=SIM,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("---- xsim run failed (%s) ----" % tag)
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        sys.exit(1)
    dst = os.path.join(SIM, "resp_%s.memh" % tag)
    shutil.copy(os.path.join(SIM, "resp.memh"), dst)
    return dst


def main():
    gen_stim_mac.generate(SIM)
    exp = os.path.join(SIM, "expected.memh")
    st  = os.path.join(SIM, "expected_stats.txt")
    ok = True
    ok &= parse_mac_rx.check(run_tb("NOSTALL", "nostall"), exp, st, tag="nostall")
    ok &= parse_mac_rx.check(run_tb("STALL", "stall"), exp, st, tag="stall")
    ok &= parse_mac_rx.check(run_tb("STALL2", "hard"), exp, st, lenient=True, tag="hard")
    print("== ALL PASS ==" if ok else "== FAILED ==")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
