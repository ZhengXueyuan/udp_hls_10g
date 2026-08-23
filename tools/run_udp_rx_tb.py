#!/usr/bin/env python
"""udp_rx 一键回归: 生成刺激 -> xsim (nostall/stall/hard 三模式) -> 参考模型逐行对拍。

用法: /c/Users/zhxue/anaconda3/python.exe tools/run_udp_rx_tb.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RXSIM = os.path.join(ROOT, "sim", "rxsim")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_udp_rx as g


def main():
    frames, hw0, hw1, csi = g.generate(RXSIM)
    print('frames=%d cfg_switch=%d hardwin=[%d,%d)' % (len(frames), csi, hw0, hw1))
    bat = os.path.join(RXSIM, "run_tb_udp_rx.bat")
    r = subprocess.run(["cmd", "/c", bat], cwd=RXSIM,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("---- xsim run failed ----")
        print(r.stdout[-4000:])
        print(r.stderr[-4000:])
        sys.exit(1)
    ok = True
    for mode in ("nostall", "stall", "hard"):
        ok = g.check(RXSIM, mode) and ok
    print("== ALL PASS ==" if ok else "== FAILED ==")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
