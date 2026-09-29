#!/usr/bin/env python
"""F4 门套的**判决器** (tripwire): 跑完不等于判了 —— 本脚本按"期望结果表"判每一路,
任何一路不符即 exit 1。用法: f4_verdict.py [--stim main|f2probe]

背景 (这是一次真实的门漏洞): F4-2 变异体 `mut` 在**主门与探针门里都是 PASS_ALL**
(它的破口是"时序撞拍", 只体现在**交付流对比**里) ⇒ 套件若只"跑门"不"算 A/B",
它看起来完全干净 (另一个 agent 就是这么读到"无区分力"的)。**判据必须显式化**。

期望结果表 (RTL 冻结; 变异体一律在 sim/f4sim/* 副本里):
  new    : 主门 PASS_ALL            且 探针 A/B(old vs new) PASS
  old    : 主门 FAIL (>=1 判据)     且 探针门 FAIL      <- 无 F4 修复
  mut    : 探针 A/B(old vs mut) FAIL                    <- F4-2 缺陷 (主门预期 PASS, 不算破)
  nogate : 主门 FAIL                                    <- TERM 优先门被拿掉 (ph_129)
  mutcrs : 主门 FAIL (L9)                               <- TERM 标志契约被改坏
缺日志 / 门被静默跳过 (exit 97 之类) 一律判 FAIL。
"""
import os
import re
import subprocess
import sys

# ⚠️ 本工程坑 16①: GBK 控制台下 print 非 ASCII 会抛 UnicodeEncodeError ⇒ **退出码变 1**
# (按 exit code 判 PASS 的自动化误报 FAIL —— 本判决器第一版就踩了: 它把"打印失败"
#  当成了"判决失败")。必须先 reconfigure, 且判决只看期望表, 不看打印是否成功。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# 期望表**按激励分档** (判别器是分工的: 主扫描抓 old/nogate/mutcrs, 探针抓 mut)
EXPECT = {
    # 主激励 (0..64 净荷扫描 + 40 相位扫描 + nodrain)
    "main": {
        "new":    {"main": "PASS", "probe_ab": "PASS"},
        "old":    {"main": "FAIL", "probe_gate": "FAIL"},
        "mut":    {"main": None,   "probe_ab": "FAIL"},   # 时序型: 只由 A/B 抓
        "nogate": {"main": "FAIL", "probe_ab": None},     # ph_129
        "mutcrs": {"main": "FAIL", "probe_ab": None},     # L9
    },
    # 探针激励 (TERM-等待 vs 新帧相位): 只保证 new 不倒退 + old/mut 被抓
    "f2probe": {
        "new":    {"probe_ab": "PASS"},
        "old":    {"probe_gate": "FAIL"},
        "mut":    {"probe_ab": "FAIL"},
        "nogate": {},
        "mutcrs": {},
    },
}


def gate_verdict(log):
    """返回 ('PASS'|'FAIL'|'MISSING', 明细字符串)。"""
    if not os.path.exists(log):
        return "MISSING", "日志不存在 (门被跳过?)"
    txt = open(log, encoding="utf-8", errors="replace").read()
    nfail = len(re.findall(r": FAIL", txt))
    if re.search(r"F4_GATE: PASS_ALL", txt):
        return "PASS", "PASS_ALL (%d 条判据)" % (txt.count("CHK L1=") and 0 or 0)
    m = re.search(r"F4_GATE: FAIL \((\d+) 条判据不成立\)", txt)
    if m:
        return "FAIL", "FAIL %s 条 (FAIL 行 %d)" % (m.group(1), nfail)
    if "XVLOG-FAIL" in txt or "XELAB-FAIL" in txt:
        return "FAIL", "编译/elaboration 失败"
    return "MISSING", "日志里找不到判定行 (门没跑完?)"


def probe_ab(old_stats, var_stats, var):
    if not (os.path.exists(old_stats) and os.path.exists(var_stats)):
        return "MISSING", "stats 文件缺失"
    p = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "f4_ab_check.py"),
                        old_stats, var_stats], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    last = [l for l in (p.stdout or "").strip().split("\n") if l.strip()]
    totals = [l for l in last if l.startswith("TOTAL")]
    tail = (totals[0] if totals else (last[-1] if last else "无输出"))
    return ("PASS" if p.returncode == 0 else "FAIL"), tail.strip()


def main():
    stim = "main"
    if "--stim" in sys.argv:
        stim = sys.argv[sys.argv.index("--stim") + 1]
    sfx = "" if stim == "main" else "_probe"
    rows, bad = [], 0
    for v, exp in EXPECT[stim].items():
        g = gate_verdict(os.path.join(HERE, ("F4_GATE_%s.log" if stim == "main"
                                            else "PROBE_%s.log") % v))
        got = {"main": g[0], "probe_gate": g[0]}
        # 探针 A/B: old(基准) vs v
        ab, abline = probe_ab(os.path.join(HERE, "rd_old", "f4_case_stats.txt"),
                              os.path.join(HERE, "rd_%s" % v, "f4_case_stats.txt"), v)
        got["probe_ab"] = ab if v != "old" else None
        for key, want in exp.items():
            if want is None:
                continue
            if got.get(key) != want:
                bad += 1
                rows.append("FAIL %-7s %-10s 期望 %s 实测 %s" % (v, key, want, got.get(key)))
            else:
                rows.append("ok   %-7s %-10s = %s" % (v, key, got.get(key)))
        rows.append("      %-7s 主门=%s(%s) 探针门=%s | 探针A/B(old vs %s)=%s : %s"
                    % (v, g[0], g[1], got["probe_gate"], v, got["probe_ab"], abline))
    print("=== F4 VERDICT (stim=%s) ===" % stim)
    for r in rows:
        print(r)
    print("F4_VERDICT: %s (%d 条期望不符)" % ("PASS" if bad == 0 else "FAIL", bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
