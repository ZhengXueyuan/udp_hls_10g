#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_gates2.py — mac_tx_64 / F-2 专项门 (在**冻结树**上重跑) + F-4 相邻门。

这些门的判据形态与 run_gates.py 的 "bat 退出码 + marker" 不同, 所以单独一支:
  A. t3_txcdc (F-2 CDC 边界链门): 4 个变体 —— pos / nostall_new (期望 PASS)
                                  + orig / nostall_orig (撤回 S_FLUSH 的**负对照**)。
     跨用例判据: nostall_new 与 nostall_orig 的 **FPRINT wf 必须逐位相同**
     (证明 F-2 对"不发生中止"的流量零影响 —— 铁律②"判据要有区分能力"的正对照)。
     期望表:  pos=PASS  nostall_new=PASS  orig=FAIL(ghost=1)  nostall_orig=PASS
  B. regress_mactx.py: mac_tx_64 的 **golden 模型**逐拍比对 (tools/parse_tx.py.check),
     4 个组合: new/main new/abort orig/main orig/abort。
     期望表: new/main=PASS new/abort=PASS orig/main=PASS **orig/abort=FAIL**(幽灵帧)。

铁律: ① 每个门必须打印判据数 (>0); ② 负对照**必须真的 FAIL**; ③ 原始 stdout 全部落盘。
"""
import hashlib
import os
import re
import subprocess
import sys

# 坑 16①: GBK 控制台下 print 非 ASCII 会抛 UnicodeEncodeError (项目记忆里的实测坑)
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = r"D:\repo\XCKU5PMini\udp_hls_10g"
HERE = os.path.join(ROOT, "p6b_final_verify")
OUT = os.path.join(HERE, "out")
os.makedirs(OUT, exist_ok=True)
R = lambda *p: os.path.join(ROOT, *p)
PY = r"C:\Users\zhxue\anaconda3\python.exe"


def md5(p):
    try:
        with open(p, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except OSError:
        return "UNREADABLE"


SOURCES = [R("rtl", "mac_tx_64.v"), R("rtl", "fifo_async.v"), R("rtl", "fifo_sync.v"),
           R("rtl", "mac_rx_64.v"), R("rtl", "crc32_8b.v"),
           R("p6b_final_verify", "t3_f2", "tb_tx_cdc_chain.v"),
           R("p6b_final_verify", "t3_f2", "mac_tx_64_orig.v"),
           R("p6b_final_verify", "rtl_orig", "mac_tx_64.v"),
           R("tools", "gen_stim_tx.py"), R("tools", "parse_tx.py"),
           R("tb", "tb_mac_tx_64.v")]


def snap():
    return {os.path.relpath(p, ROOT): md5(p) for p in SOURCES}


def sh(cmd, logname):
    log = os.path.join(OUT, logname)
    with open(log, "wb") as f:
        p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT)
    txt = open(log, "r", encoding="utf-8", errors="replace").read()
    return p.returncode, txt, os.path.relpath(log, ROOT)


def main():
    before = snap()
    print("=== 源 md5 (跑门时刻) ===")
    for k, v in sorted(before.items()):
        print("   %s  %s" % (v, k))

    results = []

    # ---------- A. t3_txcdc: 4 变体 ----------
    t3_expect = {"pos": "PASS", "nostall_new": "PASS",
                 "orig": "FAIL", "nostall_orig": "PASS"}
    fprints = {}
    for case, exp in t3_expect.items():
        rc, txt, log = sh(["cmd", "/c",
                           os.path.join(HERE, "run_t3_f2.bat"), case],
                          "t3f2_%s.log" % case)
        got = "PASS" if "TXCHAIN: PASS_ALL" in txt else "FAIL"
        m = re.search(r"FPRINT wf=(\S+) frames=(\d+) abort=(\d+) flush_words=(\d+) flush_done=(\d+)", txt)
        if m:
            fprints[case] = m.group(1)
        ghost = re.search(r"ghost=(\d+)", txt)
        ok = (got == exp)
        results.append(("t3_f2_%s" % case, "PASS" if ok else "FAIL", rc, exp, got,
                        "ghost=%s" % (ghost.group(1) if ghost else "?"), log))
        print("  t3[%-12s] expect=%-4s got=%-4s rc=%s ghost=%s  %s" %
              (case, exp, got, rc, ghost.group(1) if ghost else "?", log))

    # 跨用例: nostall_new vs nostall_orig 的线上流指纹必须相同
    fn, fo = fprints.get("nostall_new"), fprints.get("nostall_orig")
    if fn and fo:
        same = (fn == fo)
        print("  FPRINT nostall_new=%s nostall_orig=%s => %s" %
              (fn, fo, "MATCH" if same else "DIFFER"))
        results.append(("t3_f2_nostall_FPRINT_match",
                        "PASS" if same else "FAIL", 0, "MATCH",
                        "MATCH" if same else "DIFFER", "wf=%s/%s" % (fn, fo), ""))
    else:
        results.append(("t3_f2_nostall_FPRINT_match", "FAIL", 0, "MATCH",
                        "MISSING-READOUT", "", ""))

    # ---------- B. regress_mactx.py: golden 模型逐拍比对 ----------
    expect_map = {("new", "main"): "PASS", ("new", "abort"): "PASS",
                  ("orig", "main"): "PASS", ("orig", "abort"): "FAIL"}
    rc, txt, log = sh([PY, os.path.join(HERE, "regress_mactx.py"), "both"],
                      "regress_mactx.log")
    # ⚠️ 空读数 != 真 0 (本脚本第一版踩过): 若 RTL 路径写错, xvlog 报 "Can not find file",
    #    parse_tx.check 返回 False ⇒ 打出 "FAIL" —— 这与"负对照真被抓住"**在文本上不可区分**,
    #    于是 orig/abort 的 FAIL 会变成**假通过**。⇒ 必须先要求每个组合都有它的 **DONE 读数行**
    #    ("[w/m] DONE frames=..."), 缺任一 ⇒ 整组 MISSING-EVIDENCE。
    for (w, m), exp in expect_map.items():
        ran = re.search(r"\[%s/%s\] DONE frames=\d+" % (w, m), txt)
        if not ran:
            results.append(("regress_mactx_%s_%s" % (w, m), "FAIL", rc, exp,
                            "MISSING-EVIDENCE(no DONE line)", "", log))
            print("  regress[%-4s/%-5s] expect=%-4s got=MISSING-EVIDENCE(no DONE line)  %s"
                  % (w, m, exp, log))
            continue
        mm = re.search(r"^\s+%s/%s\s+(PASS|FAIL)\s*$" % (w, m), txt, re.M)
        got = mm.group(1) if mm else "MISSING-READOUT"
        results.append(("regress_mactx_%s_%s" % (w, m),
                        "PASS" if got == exp else "FAIL", rc, exp, got, "", log))
        print("  regress[%-4s/%-5s] expect=%-4s got=%-4s  %s" % (w, m, exp, got, log))

    # ---------- C. legacy TB + legacy 中止型激励: 负数对照 ----------
    #   sim/tx_*.memh 是**中止型**激励 (中间 GAP=2710 拍 > mac_tx 的帧内超时):
    #     F-2 修前 => 残字被下一个 S_IDLE 当新帧首字 ⇒ 幽灵帧 ⇒ frames=1
    #     F-2 修后 => S_FLUSH 吞到本帧 TLAST ⇒ frames=0
    #   ⇒ 同一 TB + 同一激励, 只换 mac_tx_64.v (new / orig) 就能判别 F-2 是否在位。
    #   判据: new => frames=0 abort=1 ; orig => frames=1 abort=1 (负对照必须"抓到")
    XV = r"C:\AMDDesignTools\2025.2\Vivado\bin"
    for which, rtl, want_frames in (("new", R("rtl", "mac_tx_64.v"), "0"),
                                    ("orig", R("p6b_final_verify", "t3_f2",
                                               "mac_tx_64_orig.v"), "1")):
        d = os.path.join(HERE, "legacytx", which)
        os.makedirs(d, exist_ok=True)
        for f in ("tx_ty.memh", "tx_data.memh", "tx_keep.memh", "tx_last.memh", "tx_gap.memh"):
            with open(R("sim", f), "rb") as s, open(os.path.join(d, f), "wb") as t:
                t.write(s.read())
        cmds = [
            [os.path.join(XV, "xvlog.bat"), "-work", "xil_defaultlib",
             R("rtl", "crc32_8b.v"), R("rtl", "fifo_sync.v"), rtl,
             R("tb", "tb_mac_tx_64.v")],
            [os.path.join(XV, "xelab.bat"), "-debug", "typical", "-timescale", "1ns/1ps",
             "-L", "xil_defaultlib", "xil_defaultlib.tb_mac_tx_64", "-s", "tb_snap",
             "-log", "xelab.log"],
            [os.path.join(XV, "xsim.bat"), "tb_snap", "-runall", "-log", "xsim.log"],
        ]
        rc = 0
        for c in cmds:
            pr = subprocess.run(c, cwd=d, capture_output=True, text=True)
            rc = pr.returncode
            if rc != 0 and c[0].endswith("xvlog.bat"):
                print("   [legacy/%s] xvlog FAILED: %s" % (which, pr.stdout[-800:]))
                break
        log = os.path.join(OUT, "legacytx_%s.log" % which)
        try:
            txt = open(os.path.join(d, "xsim.log"), errors="replace").read()
        except OSError:
            txt = ""
        open(log, "w", encoding="utf-8").write(txt)
        m = re.search(r"DONE frames=(\d+) abort=(\d+)", txt)
        got = m.groups() if m else None
        expect_txt = "frames=%s abort=1" % want_frames
        ok = bool(got) and got[0] == want_frames and got[1] == "1"
        results.append(("legacy_tx_%s" % which, "PASS" if ok else "FAIL", rc,
                        expect_txt, "frames=%s abort=%s" % got if got else "MISSING-READOUT",
                        "F-2 在位" if which == "new" else "负对照(撤回 F-2)", os.path.relpath(log, ROOT)))
        print("  legacy_tx[%-4s] expect=%-18s got=%s  %s" %
              (which, expect_txt, got, os.path.relpath(log, ROOT)))

    after = snap()
    stable = (before == after)
    if not stable:
        for k in before:
            if before[k] != after[k]:
                print("  !! SRC CHANGED MID-RUN: %s  %s -> %s" % (k, before[k], after[k]))

    print("\n=== SUMMARY ===")
    bad = 0
    for name, verdict, rc, exp, got, extra, log in results:
        if verdict != "PASS":
            bad += 1
        print("  [%s] %-34s exp=%-6s got=%-16s %s" %
              ("ok " if verdict == "PASS" else "BAD", name, exp, got, extra))
    print("\nGATES2: bad=%d / total=%d   src-stable=%s" %
          (bad, len(results), stable))
    return 1 if bad or not stable else 0


if __name__ == "__main__":
    sys.exit(main())
