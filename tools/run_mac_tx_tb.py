#!/usr/bin/env python
"""mac_tx_64 一键回归: 双模式 (main / abort) 各自 生成刺激+期望模型 -> xsim -> 逐拍比对。"""
import os
import sys
import subprocess
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.path.join(ROOT, "sim")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_tx
import parse_tx


def run_mode(mode):
    gen_stim_tx.generate(SIM, mode)
    bat = os.path.join(SIM, "run_tb_tx.bat")
    r = subprocess.run(["cmd", "/c", bat, "NOSTALL"], cwd=SIM,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("---- xsim run failed (%s) ----" % mode)
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        sys.exit(1)
    shutil.copy(os.path.join(SIM, "resp_tx.memh"),
                os.path.join(SIM, "resp_tx_%s.memh" % mode))
    return parse_tx.check(os.path.join(SIM, "resp_tx.memh"),
                          os.path.join(SIM, "expected_tx.memh"),
                          os.path.join(SIM, "expected_tx_stats.txt"),
                          tag=mode)


def main():
    ok = True
    ok &= run_mode("main")
    ok &= run_mode("abort")
    print("== ALL PASS ==" if ok else "== FAILED ==")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
