#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_gates.py — P6b 最终重建: 在**冻结树**上全量重跑单元门 + 全链门, 并自证
               "验过的版本 == 出货版本" (每个门记 RTL/TB 的 md5, 门前后各记一次)。

用法: python run_gates.py [gate_name ...]     (无参数 = 全部)

铁律自查:
 ① 空读数 != 真 0 —— 每个门必须有非空 PASS 标志, 否则记 MISSING-EVIDENCE 而不是 PASS。
 ② 判据要有区分能力 —— 这些门自身已带负对照 (mut* 期望 FAIL); 本脚本**核对**
    负对照真的 FAIL 了 (否则记 NEGCTL-NOT-CAUGHT)。
 ③ 结论必须有原始证据 —— 每个门的完整 stdout 落盘到 out/<gate>.log。
"""
import hashlib
import os
import re
import subprocess
import sys
import time

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


def _rx64_golden():
    """sim/expected_stats.txt = 'frames crc_err drop bytes' (tb_mac_rx_64 的 golden)"""
    try:
        with open(R("sim", "expected_stats.txt"), "r", encoding="utf-8",
                  errors="replace") as f:
            return tuple(int(x) for x in f.read().split())
    except (OSError, ValueError):
        return None


RX64_GOLDEN = _rx64_golden()

# ---------------------------------------------------------------------------
# 门定义: name -> dict(bat, args, srcs, expect, pass_marker, negctl)
#   srcs      = 该门真正编译的源文件 (md5 记录对象)
#   expect    = "OK" 或 "FAIL" (负对照)
#   marker    = 日志里必须出现的通过标志 (空读数 != 真 0)
# ---------------------------------------------------------------------------
GATES = {
    # ---------- 单元门 ----------
    "fifoasync_all": dict(
        bat=R("sim", "fifoasync", "run_all.bat"), args=[], expect="OK",
        marker="FIFO_ASYNC_GATE_ALL: OK",
        srcs=[R("rtl", "fifo_async.v"), R("tb", "tb_fifo_async.v")],
        note="7 正例 + 6 变异 (变异期望 CAUGHT)"),
    # ⚠️ 这三个 TB 是**激励发生器** (读 stim_*.memh / tx_*.memh → 写 resp*.memh)。
    #    tb_mac_rx_64 有 **golden**: sim/expected_stats.txt = "frames crc_err drop bytes"
    #    (实测该文件内容 = "11 1 0 2140" —— 激励**故意**含 1 个坏 FCS 帧, 所以 crc_err=1
    #     才是期望值; 第一版判据我猜 crc_err==0, 被 READOUT-OUT-OF-SPEC 拦下来 = 判据在干活)。
    #    tb_mac_tx_64 的 legacy 激励是**中止型**, 判据见下面 want + gates2 的负对照。
    "tb_mac_rx_64_nostall": dict(
        bat=R("sim", "run_tb.bat"), args=["NOSTALL"], expect="OK",
        marker="DONE frames=", readout=r"DONE frames=(\d+) crc_err=(\d+) drop=(\d+) bytes=(\d+)",
        want=lambda g: tuple(int(x) for x in g) == RX64_GOLDEN,
        srcs=[R("rtl", "mac_rx_64.v"), R("rtl", "fifo_sync.v"),
              R("rtl", "crc32_8b.v"), R("tb", "tb_mac_rx_64.v"),
              R("sim", "expected_stats.txt"), R("sim", "stim_data.memh")],
        note="mac_rx_64 发生器 TB (读数 必须逐字段 == sim/expected_stats.txt)"),
    "tb_mac_rx_64_stall": dict(
        bat=R("sim", "run_tb.bat"), args=["STALL"], expect="OK",
        marker="DONE frames=", readout=r"DONE frames=(\d+) crc_err=(\d+) drop=(\d+) bytes=(\d+)",
        want=lambda g: tuple(int(x) for x in g) == RX64_GOLDEN,
        srcs=[R("rtl", "mac_rx_64.v"), R("rtl", "fifo_sync.v"),
              R("rtl", "crc32_8b.v"), R("tb", "tb_mac_rx_64.v"),
              R("sim", "expected_stats.txt"), R("sim", "stim_data.memh")],
        note="mac_rx_64 发生器 TB (背压抖动; 读数判据同 NOSTALL)"),
    # mac_tx 的 legacy 激励 (sim/tx_*.memh) **本身就是中止型** (中间 GAP=2710 拍):
    #   F-2 修前 => 残字成幽灵帧 ⇒ frames=1 ; F-2 修后 => S_FLUSH 吞净 ⇒ frames=0。
    #   ⇒ frames=0 & abort=1 是**只有修后才成立**的读数 (负对照在下面 neg_legacy_tx)。
    "tb_mac_tx_64_nostall": dict(
        bat=R("sim", "run_tb_tx.bat"), args=["NOSTALL"], expect="OK",
        marker="DONE frames=", readout=r"DONE frames=(\d+) abort=(\d+)",
        want=lambda g: int(g[0]) == 0 and int(g[1]) == 1,
        srcs=[R("rtl", "mac_tx_64.v"), R("rtl", "fifo_sync.v"),
              R("rtl", "crc32_8b.v"), R("tb", "tb_mac_tx_64.v"),
              R("sim", "tx_data.memh")],
        note="mac_tx_64 发生器 TB —— 读数 frames=0/abort=1 是 F-2 修后才成立的形态"),
    "tb_clk_gen_p6b": dict(
        bat=R("sim", "clkgen", "run_tb_clk_gen_p6b.bat"), args=[], expect="OK",
        marker="PASS", srcs=[R("rtl", "clk_gen_p6b.v"), R("tb", "tb_clk_gen_p6b.v")],
        note="双域时钟/复位桥"),
    "tb_snap_seq": dict(
        bat=R("sim", "snapseq", "run_tb_snap_seq.bat"), args=[], expect="OK",
        marker="PASS", srcs=[R("rtl", "snap_seq.v"), R("tb", "tb_snap_seq.v")],
        note="链式快照序列器"),
    "tb_snap_cdc": dict(
        bat=R("sim", "snapcdc", "run_tb_snap_cdc.bat"), args=[], expect="OK",
        marker="PASS", srcs=[R("rtl", "snap_cdc.v"), R("tb", "tb_snap_cdc.v")],
        note="相干快照 CDC"),
    "tb_axi_regs": dict(
        bat=R("_proj_pcie", "run_tb_axi_regs.bat"), args=[], expect="OK",
        marker="PASS", srcs=[R("_proj_pcie", "rtl", "axi_regs.v"),
                             R("_proj_pcie", "tb", "tb_axi_regs.v")],
        note="PCIe 寄存器窗口"),
    # ---------- F4 专项门 (mac_rx_64 的修复本体) ----------
    "f4_suite": dict(
        bat=R("sim", "f4sim", "run_f4_suite.bat"), args=[], expect="OK",
        marker="SUITE DONE",
        srcs=[R("rtl", "mac_rx_64.v"), R("rtl", "fifo_sync.v"),
              R("tb", "tb_mac_rx_f4.v"), R("tb", "tb_f4_chain.v")],
        note="F4 门 x5 变体 + A/B x2 + bitexact + mac regress x3 + chain x2"),
    # ---------- 全链门 ----------
    "p6e_pcie_wrapper": dict(
        bat=R("sim", "p6e_pcie", "run_tb_p6e_pcie.bat"), args=[], expect="OK",
        marker="PASS_ALL",
        srcs=[R("board", "wrapper_p4.v"), R("sim", "p6e_pcie", "tb_p6e_pcie_wrapper.v")],
        note="真 wrapper 全链 (坑 8)"),
    "p6e_pcie_counters": dict(
        bat=R("sim", "p6e_pcie", "run_tb_p6e_pcie_counters.bat"), args=[], expect="OK",
        marker="PASS_ALL",
        srcs=[R("board", "wrapper_p4.v"), R("sim", "p6e_pcie", "tb_p6e_pcie_counters.v")],
        note="计数器增量逻辑门"),
}

# 负对照门 (期望非零退出) —— 用同一支脚本的不同参数
NEGCTLS = {
    "negctl_run_tb_mac_rx_old": dict(
        bat=R("sim", "f4sim", "run_tb_f4_mac.bat"), args=["old"], expect="FAIL",
        marker="F4-GATE-RESULT: FAIL",
        srcs=[R("sim", "f4sim", "prefix_rtl", "mac_rx_64.v")],
        note="F4 门自身负对照: 修复前 RTL ⇒ 必须 FAIL"),
    "negctl_run_tb_mac_nogate": dict(
        bat=R("sim", "f4sim", "run_tb_f4_mac.bat"), args=["nogate"], expect="FAIL",
        marker="F4-GATE-RESULT: FAIL",
        srcs=[R("sim", "f4sim", "mut_nogate", "mac_rx_64.v")],
        note="TERM 优先门移除 ⇒ 必须 FAIL"),
}


def md5(p):
    try:
        with open(p, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except OSError as e:
        return "UNREADABLE(%s)" % e.__class__.__name__


def snap(srcs):
    return {os.path.relpath(p, ROOT): md5(p) for p in srcs}


def run(name, d):
    print("=" * 78)
    print("GATE %s  (%s)" % (name, d.get("note", "")))
    print("=" * 78)
    before = snap(d["srcs"])
    for k, v in sorted(before.items()):
        print("   src-before  %s  %s" % (v, k))
    log = os.path.join(OUT, name + ".log")
    t0 = time.time()
    with open(log, "wb") as f:
        try:
            p = subprocess.run([d["bat"]] + d["args"], stdout=f, stderr=subprocess.STDOUT,
                               cwd=os.path.dirname(d["bat"]))
            rc = p.returncode
        except Exception as e:  # noqa: BLE001
            f.write(("EXCEPTION: %r\n" % (e,)).encode())
            rc = -999
    dt = time.time() - t0
    after = snap(d["srcs"])
    txt = open(log, "r", encoding="utf-8", errors="replace").read()

    # 判据: ① 退出码方向正确 ② 通过标志真出现 (空读数 != 真 0) ③ 源没被中途改
    exp = d["expect"]
    rc_ok = (rc == 0) if exp == "OK" else (rc != 0)
    mk_ok = d["marker"] in txt
    stable = (before == after)

    # 读数 (若门声明了 readout 正则): 空读数 => 判据不成立
    readout = None
    if d.get("readout"):
        m = re.search(d["readout"], txt)
        readout = m.groups() if m else None

    if exp == "OK":
        verdict = "PASS" if (rc_ok and mk_ok and stable) else "FAIL"
    else:
        verdict = "NEGCTL-CAUGHT" if (rc_ok and mk_ok and stable) else "NEGCTL-NOT-CAUGHT"

    if not stable:
        verdict += "/SRC-CHANGED-MIDRUN"
    if not mk_ok:
        verdict = "MISSING-EVIDENCE" if exp == "OK" else verdict
    # 空读数 != 真 0: 有 readout 的门, 读数取不到就降级
    if d.get("readout"):
        if readout is None:
            if verdict.startswith("PASS"):
                verdict = "MISSING-EVIDENCE"
        elif d.get("want") and not d["want"](readout):
            verdict = "READOUT-OUT-OF-SPEC"

    print("   rc=%s (expect %s) marker=%r size=%dB %.1fs" %
          (rc, exp, mk_ok, len(txt), dt))
    if d.get("readout"):
        print("   READOUT %s = %s" % (d["readout"], readout))
    print("   VERDICT: %s" % verdict)
    return dict(name=name, verdict=verdict, rc=rc, expect=exp,
                marker_found=mk_ok, seconds=round(dt, 1), readout=readout,
                log=os.path.relpath(log, ROOT), srcs_before=before, srcs_after=after,
                stable=stable, note=d.get("note", ""))


def main():
    want = sys.argv[1:]
    results = []
    for table in (GATES, NEGCTLS):
        for name, d in table.items():
            if want and name not in want:
                continue
            try:
                results.append(run(name, d))
            except Exception as e:  # noqa: BLE001
                print("GATE %s CRASHED: %r" % (name, e))
                results.append(dict(name=name, verdict="CRASHED", rc=None,
                                    srcs_before={}, srcs_after={}, stable=False))
    print("\n" + "=" * 78)
    print("SUMMARY")
    print("=" * 78)
    import json
    with open(os.path.join(HERE, "gates_summary.json"), "w", encoding="utf-8") as f:
        json.dump(results, f, indent=1)
    bad = 0
    for r in results:
        ok = r["verdict"] in ("PASS", "NEGCTL-CAUGHT")
        if not ok:
            bad += 1
        print("  [%s] %-28s rc=%-5s %s" %
              ("ok " if ok else "BAD", r["name"], r["rc"], r["verdict"]))
    print("\nGATES: bad=%d / total=%d" % (bad, len(results)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
