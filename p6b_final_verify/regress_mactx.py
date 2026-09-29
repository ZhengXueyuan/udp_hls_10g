#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""regress_mactx.py -- 用**工程既有**的 mac_tx_64 单元门做回归 (F-2 修复后)。

为什么不直接跑 sim/run_tb_tx.bat: 那个 bat 里 `cd /d D:\\repo\\ECO\\udp_hls_10g\\sim`
(指向被拷的原仓库), 会跑到**另一份 RTL**。本脚本把刺激/期望/trace 全部落在
audit_scratch/t6_mactx/ 下, 只引用 tools/ 里既有的 gen_stim_tx.py / parse_tx.py
(**未修改任何既有文件**), 编译本目录的 rtl/mac_tx_64.v (或它的旧副本)。

用法: python regress_mactx.py [new|orig|both]     (默认 both)
  new  = rtl/mac_tx_64.v (F-2 修复后) ; orig = audit_scratch/rtl_orig/mac_tx_64.v
判据 = parse_tx.check (逐拍比对 gmii 流 + stats)。
"""
import os
import sys
import shutil
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
sys.path.insert(0, TOOLS)
import gen_stim_tx          # noqa: E402
import parse_tx             # noqa: E402

XV = r"C:\AMDDesignTools\2025.2\Vivado\bin"
TB = os.path.join(ROOT, "tb", "tb_mac_tx_64.v")
BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "t6_mactx")
RTL = {
    "new":  os.path.join(ROOT, "rtl", "mac_tx_64.v"),
    "orig": os.path.join(os.path.dirname(os.path.abspath(__file__)), "rtl_orig", "mac_tx_64.v"),
}


def run_one(which, mode):
    d = os.path.join(BASE, which, mode)
    os.makedirs(d, exist_ok=True)
    shutil.rmtree(os.path.join(d, "xsim.dir"), ignore_errors=True)
    gen_stim_tx.generate(d, mode)
    xvlog = os.path.join(XV, "xvlog.bat")
    xelab = os.path.join(XV, "xelab.bat")
    xsim = os.path.join(XV, "xsim.bat")
    r = subprocess.run([xvlog, "-work", "xil_defaultlib",
                        os.path.join(ROOT, "rtl", "crc32_8b.v"),
                        os.path.join(ROOT, "rtl", "fifo_sync.v"),
                        RTL[which], TB],
                       cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        print("[%s/%s] xvlog FAILED\n%s" % (which, mode, r.stdout[-2000:]))
        return False
    r = subprocess.run([xelab, "-debug", "typical", "-timescale", "1ns/1ps",
                        "-L", "xil_defaultlib", "xil_defaultlib.tb_mac_tx_64",
                        "-s", "tb_snap", "-log", "xelab.log"],
                       cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        print("[%s/%s] xelab FAILED\n%s" % (which, mode, r.stdout[-2000:]))
        return False
    subprocess.run([xsim, "tb_snap", "-runall", "-log", "xsim.log"],
                   cwd=d, capture_output=True, text=True)
    with open(os.path.join(d, "xsim.log"), errors="replace") as fh:
        for ln in fh:
            if "DONE" in ln:
                print("   [%s/%s] %s" % (which, mode, ln.strip()))
    ok = parse_tx.check(os.path.join(d, "resp_tx.memh"),
                        os.path.join(d, "expected_tx.memh"),
                        os.path.join(d, "expected_tx_stats.txt"),
                        tag="%s/%s" % (which, mode))
    shutil.copy(os.path.join(d, "resp_tx.memh"),
                os.path.join(BASE, "resp_tx_%s_%s.memh" % (which, mode)))
    return ok


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    modes = ["main", "abort"]
    res = {}
    for w in (["new", "orig"] if which == "both" else [which]):
        for m in modes:
            print("---- mac_tx_64 unit gate [%s / %s] ----" % (w, m))
            res[(w, m)] = run_one(w, m)
    print("== 汇总 ==")
    for k in sorted(res):
        print("   %-12s %s" % ("%s/%s" % k, "PASS" if res[k] else "FAIL"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
