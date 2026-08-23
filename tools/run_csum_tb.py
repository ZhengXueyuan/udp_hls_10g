#!/usr/bin/env python
"""一键回归: 生成刺激 -> xsim -> 逐拍对拍 (valid 脉冲位置 + csum 值 + 独立参考)。

用法: /c/Users/zhxue/anaconda3/python.exe tools/run_csum_tb.py
"""
import os
import sys
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "sim")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_csum


def main():
    script, refs = gen_stim_csum.generate(SIM)
    print('frames=%d script_lines=%d' % (len(refs), len(script)))
    bat = os.path.join(SIM, "run_tb_csum.bat")
    r = subprocess.run(["cmd", "/c", bat], cwd=SIM,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("---- xsim run failed ----")
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        sys.exit(1)
    ok = gen_stim_csum.check(SIM)
    print("== ALL PASS ==" if ok else "== FAILED ==")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
