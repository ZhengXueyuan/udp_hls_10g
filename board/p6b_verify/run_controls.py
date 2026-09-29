#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
# run_controls.py — P6b 时序闸 (board/check_p6b_timing.py) 的**区分能力自证**
#
#   为什么需要它: 闸如果没有负对照, 就无法证明它"抓得住" —— 一个永远打印 PASS 的脚本
#   与一个真会判的脚本, 在只有正例的时候**读数完全一样** (本工程铁律②)。
#   所以这里把"喂什么进去 ⇒ 必须出什么结论"写成**可执行的期望表**, 任何一条不符就非零退出。
#
#   输入全部是**仓里已有的真实报告** (不自己编造"像样"的报告):
#     正对照  board/p6e_ku5p_timing.rpt                       (P6e 8.0ns 单约束, 0 失败端点)
#     负对照  p6a_ku5p_verify/p6a_t6p4_timing_summary_routed.rpt (整设计 6.400ns ⇒ 16 条 Min-Period 违例)
#     旁证    p6a_ku5p_verify/p6a_t8p0_...rpt, board/p6e_verify/p6e_timing_summary.routed.rpt
#   病理样本 = 从上面真实报告**逐字改一处**生成 (人工构造, 文件里带 SYNTHETIC 标记):
#     path_setup_fail1 / path_hold_fail2 / path_clock_5ns / path_verdict_notmet
#     SYNTH_dual_ok  (给 p6e 补一个干净的 6.400ns 域 ⇒ 演示"双域报告判 PASS"这条路)
#
#   用法: python board/p6b_verify/run_controls.py            (全部对照 + 写原始输出)
#         python board/p6b_verify/run_controls.py --make-only (只生成病理样本)
#   产物: board/p6b_verify/*.txt (各次运行的**原始 stdout**) + CONTROLS.txt (期望/实测对照表)
# =============================================================================
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TOOL = os.path.join(ROOT, "board", "check_p6b_timing.py")
RPTS = {
    "p6e_8ns":   os.path.join(ROOT, "board", "p6e_ku5p_timing.rpt"),
    "p6e_verify": os.path.join(ROOT, "board", "p6e_verify", "p6e_timing_summary.routed.rpt"),
    "t6p4":      os.path.join(ROOT, "p6a_ku5p_verify", "p6a_t6p4_timing_summary_routed.rpt"),
    "t8p0":      os.path.join(ROOT, "p6a_ku5p_verify", "p6a_t8p0_timing_summary_routed.rpt"),
}
# 病理样本放这里 (生成物, 但入库 —— 审计时要能直接复跑 check 工具)
PATH_DIR = os.path.join(HERE, "path")

SYNTH_MARK = ("# !!! SYNTHETIC / 人工构造样本 (非 Vivado 产物): 由 board/p6b_verify/run_controls.py "
              "从真实报告逐字改一处生成, 仅供本工具的正负对照使用 !!!")

# =============================================================================
# 生成病理样本
# =============================================================================
def _read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()

def _write(p, txt):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(txt)

def _mark(txt):
    """在报告头之后插入 SYNTHETIC 标记 (不改动任何被判据读取的行)"""
    i = txt.find("Timing Summary Report")
    return txt[:i] + SYNTH_MARK + "\n\n" + txt[i:] if i > 0 else SYNTH_MARK + "\n" + txt

DTS_ROW = re.compile(
    r"(^\s*)(" + r"[-\d.]+" + r")(\s+)(" + r"[-\d.]+" + r")(\s+)(\d+)(\s+)(\d+)"
    r"(\s+)(" + r"[-\d.]+" + r")(\s+)(" + r"[-\d.]+" + r")(\s+)(\d+)(\s+)(\d+)"
    r"(\s+)(" + r"[-\d.]+" + r")(\s+)(" + r"[-\d.]+" + r")(\s+)(\d+)(\s+)(\d+)(\s*)$", re.M)

def _patch_dts(txt, **kw):
    """只改 Design Timing Summary 那一行的数字 (WNS/TNS/fail/total × setup/hold/pw)"""
    i = txt.find("Design Timing Summary")
    assert i > 0, "找不到 Design Timing Summary"
    head, tail = txt[:i], txt[i:]
    m = DTS_ROW.search(tail)
    assert m, "Design Timing Summary 的 12 数行没匹配上"
    g = m.groups()
    vals = [g[1], g[3], g[5], g[7], g[9], g[11], g[13], g[15], g[17], g[19], g[21], g[23]]
    keys = ["wns", "tns", "setup_fail", "setup_tot", "whs", "ths", "hold_fail", "hold_tot",
            "wpws", "tpws", "pw_fail", "pw_tot"]
    seps = [g[0], g[2], g[4], g[6], g[8], g[10], g[12], g[14], g[16], g[18], g[20], g[22], g[24]]
    for k, v in kw.items():
        vals[keys.index(k)] = v
    out = "".join(seps[j] + vals[j] for j in range(12)) + seps[12]
    return head + tail[:m.start()] + out + tail[m.end():]

def make_pathologies():
    os.makedirs(PATH_DIR, exist_ok=True)
    made = []
    p6e = _read(RPTS["p6e_8ns"])
    t6 = _read(RPTS["t6p4"])

    # ---- P1: WNS 仍为正, 但 setup 失败端点数 0 -> 1 (抓"只看 WNS 就判 PASS") ----
    t = _patch_dts(p6e, tns="-0.123", setup_fail="1")
    _write(os.path.join(PATH_DIR, "path_setup_fail1.rpt"), _mark(t))
    made.append("path_setup_fail1.rpt")

    # ---- P2: WHS 仍为正, 但 hold 失败端点数 0 -> 2 ----
    t = _patch_dts(p6e, ths="-0.045", hold_fail="2")
    _write(os.path.join(PATH_DIR, "path_hold_fail2.rpt"), _mark(t))
    made.append("path_hold_fail2.rpt")

    # ---- P3: 把一个时钟域改成 5.000ns (200MHz) ⇒ family 变成 {8.0, 5.0}, 既无 6.4 也不齐 ----
    t = re.sub(r"^(\s*gmii_clk\s+\{\s*0\.000\s+)\d+(\.\d+)?(\s*\}\s+)\d+(\.\d+)?(\s+)[\d.]+(\s*)$",
               r"\g<1>2.500\g<3>5.000\g<5>200.000\g<6>", p6e, count=1, flags=re.M)
    assert t != p6e, "P3: gmii_clk 行没改到"
    _write(os.path.join(PATH_DIR, "path_clock_5ns.rpt"), _mark(t))
    made.append("path_clock_5ns.rpt")

    # ---- P4: 只把总判行翻成 not met (其余四列全过) ⇒ 抓"不看总判行" ----
    t = p6e.replace("All user specified timing constraints are met.", "Timing constraints are not met.")
    assert t != p6e, "P4: 总判行没改到"
    _write(os.path.join(PATH_DIR, "path_verdict_notmet.rpt"), _mark(t))
    made.append("path_verdict_notmet.rpt")

    # ---- P0(合成正例): 给 p6e 补一个**干净**的 6.400ns 域 ⇒ 双域报告应判 PASS ----
    #   注意: 6.400ns 域上**不能**有 IDDRE1 (HDIO 器件上限 125MHz!) —— 那正是闸 G 的病。
    #   所以新域的 pulse-width 表只放合规项 (required 取自器件库, actual=6.400)。
    t = p6e
    anchor = re.search(r"^(\s*gmii_clk\s+\{\s*0\.000\s+4\.000\s*\}\s+8\.000\s+125\.000\s*)$", t, re.M)
    assert anchor, "P0: 找不到 gmii_clk 的 Clock Summary 行"
    newclk = ("  gmii_clk_dp                                                                                                                                                                                                                       "
              "{0.000 3.200}          6.400           156.250")
    t = t[:anchor.end()] + "\n" + newclk + t[anchor.end():]
    pwt = """
Pulse Width Checks
--------------------------------------------------------------------------------------
Clock Name:         gmii_clk_dp
Waveform(ns):       { 0.000 3.200 }
Period(ns):         6.400
Sources:            { u_clkgen/mmcm_dp/CLKOUT0 }

Check Type        Corner  Lib Pin                   Reference Pin  Required(ns)  Actual(ns)  Slack(ns)   Location        Pin
Min Period        n/a     BUFGCE/I                  n/a            1.499         6.400       4.901       BUFGCE_X0Y6     u_clkgen/bufg_dp/I
Min Period        n/a     RAMB36E2/CLKARDCLK        n/a            1.739         6.400       4.661       RAMB36_X3Y14    u_dp/buf_dp_U/ram_reg_bram_0/CLKARDCLK
Min Period        n/a     FDRE/C                    n/a            0.550         6.400       5.850       SLICE_X120Y80   u_dp/cnt_reg[0]/C


"""
    t = t.replace("\nPulse Width Checks\n", pwt + "Pulse Width Checks\n", 1)
    _write(os.path.join(PATH_DIR, "SYNTH_dual_ok.rpt"), _mark(t))
    made.append("SYNTH_dual_ok.rpt")
    _ = t6
    return made

# =============================================================================
# 跑对照
# =============================================================================
def run_tool(rpt, expect):
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    p = subprocess.run([sys.executable, "-X", "utf8", TOOL, rpt, "--expect", expect],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    return p.returncode, p.stdout.decode("utf-8", "replace")

def main():
    make_only = "--make-only" in sys.argv
    made = make_pathologies()
    print("生成病理样本: %s" % ", ".join(made))
    if make_only:
        return 0

    P = lambda n: os.path.join(PATH_DIR, n)
    # (输出名, 报告路径, --expect, 期望退出码, 期望里必须出现的字符串, 期望里绝不能出现的字符串)
    cases = [
        ("pos_p6e_8ns.auto",          RPTS["p6e_8ns"],    "auto",   0, "[N/A ] 判据2", "[FAIL]"),
        ("pos_p6e_8ns.single",        RPTS["p6e_8ns"],    "single", 0, "[PASS]",       "[FAIL]"),
        ("pos_p6e_8ns.dual_teeth",    RPTS["p6e_8ns"],    "dual",   1, "缺 ~6.400ns 域", ""),
        ("pos_synth_dual.dual",       P("SYNTH_dual_ok.rpt"), "dual",   0, "[PASS]",  "[FAIL]"),
        ("pos_synth_dual.auto",       P("SYNTH_dual_ok.rpt"), "auto",   0, "[PASS]",  "[FAIL]"),
        ("neg_p6a_t6p4.auto",         RPTS["t6p4"],       "auto",   1, "IDDRE1/C|CB Min-Period 违例数 | 期望=0 | 实测=10", ""),
        ("neg_p6a_t6p4.dual",         RPTS["t6p4"],       "dual",   1, "缺 ~8.000ns 域", ""),
        ("neg_path_setup_fail1.auto", P("path_setup_fail1.rpt"), "auto", 1,
         "判据=setup 失败端点数 | 期望=0 | 实测=1 ", ""),
        ("neg_path_hold_fail2.auto",  P("path_hold_fail2.rpt"),  "auto", 1,
         "判据=hold  失败端点数 | 期望=0 | 实测=2 ", ""),
        ("neg_path_clock5ns.auto",    P("path_clock_5ns.rpt"),   "auto", 1, "5.000", ""),
        ("neg_path_verdict.auto",     P("path_verdict_notmet.rpt"), "auto", 1, "Timing constraints are not met", ""),
        ("extra_p6a_t8p0.auto",       RPTS["t8p0"],       "auto",   0, "[PASS]", "[FAIL]"),
        ("extra_p6e_verify.auto",     RPTS["p6e_verify"], "auto",   0, "[PASS]", "[FAIL]"),
    ]

    idx = ["# P6b 时序闸区分能力自证 (run_controls.py)", "#",
           "# 每一行 = 一次真实的工具调用; 产物 = 同名 .txt (原始 stdout)。",
           "# 判据: 退出码 与 期望一致, 且期望出现的串出现 / 禁止出现的串不出现。",
           "# 重跑: python board/p6b_verify/run_controls.py",
           "# 输入: 仓里已有的真实报告 (board/p6e_ku5p_timing.rpt / p6a_ku5p_verify/*) +",
           "#       path/*.rpt (人工构造的病理样本, 由本脚本一键重建, 删了也没关系)", ""]
    n_bad = 0
    for name, rpt, exp, want_rc, must, must_not in cases:
        rc, out = run_tool(rpt, exp)
        _write(os.path.join(HERE, name + ".txt"), out)
        ok = (rc == want_rc)
        if must and must not in out:
            ok = False
        if must_not and must_not in out:
            ok = False
        if not ok:
            n_bad += 1
        idx.append("  [%s] %-26s --expect %-6s rc=%d (期望 %d)  %s"
                   % ("OK  " if ok else "BAD ", name, exp, rc, want_rc, os.path.basename(rpt)))
        if not ok:
            if rc != want_rc:
                idx.append("         ↑ 退出码不符")
            if must and must not in out:
                idx.append("         ↑ 缺少期望串: %r" % must)
            if must_not and must_not in out:
                idx.append("         ↑ 出现了禁止串: %r" % must_not)
    idx.append("")
    idx.append("对照结论: %d/%d 条符合期望 %s" % (len(cases) - n_bad, len(cases),
                                          "=> 闸有区分能力" if n_bad == 0 else "=> **闸的区分能力没被证明, 别上板**"))
    _write(os.path.join(HERE, "CONTROLS.txt"), "\n".join(idx) + "\n")
    print("\n".join(idx))
    return 1 if n_bad else 0

if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    sys.exit(main())
