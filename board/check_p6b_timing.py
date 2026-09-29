#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
# check_p6b_timing.py — P6b 时序报告的**机器可判**判据 (取代人肉看 rpt)
#
#   为什么单独写 (而不是改 check_p6e_timing.py):
#     P6b 把数据面时钟从 PHY 回送的 125MHz `i_rxc` 搬到**独立的 156.25MHz 自由运行域**,
#     前端 RGMII 仍留 125MHz ⇒ 报告里必须**同时**出现 ~8.000ns 与 ~6.400ns 两个约束。
#     这是 P6b 的**核心结构性判据**, 老工具 (单域) 表达不了; 而且"0 失败端点"这类判据
#     人肉看会漏 hold 段 / 漏 pulse-width 段 ⇒ 固化成判据。
#
#   用法:
#     python check_p6b_timing.py <timing_summary_routed.rpt> [--expect dual|single|auto]
#     ⭐ **P6b 正式验收: `--expect dual`** (单域报告会被判 FAIL, 这是故意的; 见下)
#
#   ---- 判据 (逐条打印 判据/期望/实测/判定) ----
#     判据1  setup 失败端点数 = 0 且 hold 失败端点数 = 0
#     判据2  存在 ~8.000ns 域 (前端 125MHz) 与 ~6.400ns 域 (数据面 156.25MHz) ——
#            用**周期值**自动发现时钟名 (网名会变, 绝不硬编码)
#     判据3  Min-Period / Pulse-Width 违例 = 0; 显式打印
#            "IDDRE1/C|CB Min-Period 违例数" (闸 G 那批在 P6b 双约束报告里必须消失)
#     判据4  WNS 报告值 与 失败端点数=0 **同时**成立 (不许"WNS 正但端点非 0"或反之而判 PASS)
#     判据5  报告自己的总判行 ("... constraints are met." / "... are not met.")
#
#   ---- 判据2 的三种语义 (`--expect`, 这是本工具唯一需要"表态"的地方) ----
#     dual   : 硬判 —— 必须同时有 ~8.000 与 ~6.400, 缺任一 ⇒ FAIL。**P6b 验收用这个。**
#     single : 声明本次是单约束/单域运行 (P6a/P6e 式的历史报告) ⇒ 判据2 记 N/A (不计 FAIL),
#              但会打印它实际发现的 family 周期, 不遮掩。
#     auto   (默认): 由报告内容推断 ——
#              * 同时有 ~8.000 与 ~6.400  ⇒ PASS (双域报告, 判据生效)
#              * family 恰好只有 1 个周期  ⇒ N/A (单域报告; 并**醒目提醒**:
#                若这是 P6b 验收, 必须 `--expect dual` 重跑, 届时本项为 FAIL)
#              * family 有 >=2 个周期但不是 {~8.000, ~6.400} ⇒ FAIL (点名实际周期)
#              * family 一个周期都没有 ⇒ FAIL (既无 8.0 也无 6.4 域, 判据无从成立)
#     ⚠️ 为什么默认 auto 而不是 dual: 老报告 (p6e 8ns 单约束) 必须能被同一支工具判 PASS,
#        否则"正对照"就没法自动化。**但自动推断不能当验收结论** —— 若 P6b 的报告里
#        6.4ns 域整个不见了, auto 也会给 N/A ⇒ 假 PASS。所以 auto 模式下这条会打印
#        `--expect dual` 的提醒, 验收流程只认 dual 的退出码。
#
#   ---- 三条铁律自查 ----
#    ① 空读数 != 真 0: 解析不出数 (None) 一律 FAIL, 绝不默认成 0 再判 PASS。
#    ② 闸要有区分能力: 正/负对照与人工病理样本的原始输出入库 board/p6b_verify/
#       (负对照 = p6a_ku5p_verify 的 t6p4 报告, 它有 16 条 Min-Period 违例)。
#    ③ 判据的界按"两模态间隔"设: 8.0 与 6.4 相差 25%, 容差取 ±3% (远小于间隔) ⇒
#       不会把 125MHz 的域误认成 156.25MHz。
#
#   退出码: 0 = 全过 (N/A 不算失败) / 1 = 有 FAIL / 2 = 报告读不了或格式不认 (工具自身失败)
# =============================================================================
import argparse
import os
import re
import sys

# ---- 判据的界 (按两模态间隔设, 不钉在样本极值上) ----
TOL        = 0.03       # 周期匹配容差 ±3% (8.0 与 6.4 相差 25%, 余量充足)
TARGET_FE  = 8.000      # 前端 125MHz
TARGET_DP  = 6.400      # 数据面 156.25MHz
FAMILY_LO  = 5.0        # "前端/数据面"家族的周期带 (排除 PCIe 10/4/2/0.2ns 与 1000ns)
FAMILY_HI  = 9.0

PASS, FAIL, NA = "PASS", "FAIL", "N/A"

# =============================================================================
# 解析
# =============================================================================
NUM = r"-?\d+(?:\.\d+)?"

def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()

def parse_header(txt):
    """报告头里的溯源信息 (证明"判的是哪一份报告")"""
    out = {}
    for key, pat in (("tool", r"^\|\s*Tool Version\s*:\s*(.+?)\s*$"),
                     ("date", r"^\|\s*Date\s*:\s*(.+?)\s*$"),
                     ("design", r"^\|\s*Design\s*:\s*(.+?)\s*$"),
                     ("device", r"^\|\s*Device\s*:\s*(.+?)\s*$"),
                     ("state", r"^\|\s*Design State\s*:\s*(.+?)\s*$")):
        m = re.search(pat, txt, re.M)
        out[key] = m.group(1) if m else "?"
    return out

def parse_design_timing_summary(txt):
    """Design Timing Summary = 一行 12 个数 (setup 4 / hold 4 / pulse-width 4)。
       ⚠️ Intra Clock Table 的每行也是 12 个数, 但它**以时钟名开头**;
          这里锚定 "| Design Timing Summary" 之后的第一条纯数字行, 不会串段。"""
    i = txt.find("Design Timing Summary")
    if i < 0:
        return None
    m = re.search(
        r"^\s*(" + NUM + r")\s+(" + NUM + r")\s+(\d+)\s+(\d+)\s+"
        r"(" + NUM + r")\s+(" + NUM + r")\s+(\d+)\s+(\d+)\s+"
        r"(" + NUM + r")\s+(" + NUM + r")\s+(\d+)\s+(\d+)\s*$",
        txt[i:], re.M)
    if not m:
        return None
    g = m.groups()
    return {
        "wns": float(g[0]), "tns": float(g[1]), "setup_fail": int(g[2]), "setup_tot": int(g[3]),
        "whs": float(g[4]), "ths": float(g[5]), "hold_fail": int(g[6]), "hold_tot": int(g[7]),
        "wpws": float(g[8]), "tpws": float(g[9]), "pw_fail": int(g[10]), "pw_tot": int(g[11]),
    }

def parse_verdict(txt):
    """报告自己的总判行 (两个互斥的句子)"""
    met = "All user specified timing constraints are met." in txt
    notmet = "Timing constraints are not met." in txt
    if met and not notmet:
        return "met"
    if notmet and not met:
        return "not_met"
    if met and notmet:          # 同时出现 (拼接/截断过的报告) ⇒ 一律按最保守
        return "both"
    return None

def _section(txt, header, stop_at_next_rule=True):
    """取出 `| <header>` 表体: 跳过分隔线, 读到下一段 `-----` 分隔线为止。"""
    i = txt.find("| " + header)
    if i < 0:
        return None
    lines = txt[i:].splitlines()
    body, started = [], False
    for ln in lines[1:]:
        if not started:
            if re.match(r"^\s*-{5,}\s+\S", ln):     # 列名的下划线行 "-----  ------------"
                started = True
            continue
        if re.match(r"^-{10,}\s*$", ln) and stop_at_next_rule:
            break
        body.append(ln)
    return "\n".join(body)

CLOCK_ROW = re.compile(r"^\s*(\S+)\s+\{\s*(" + NUM + r")\s+(" + NUM + r")\s*\}\s+(" + NUM + r")\s+(" + NUM + r")\s*$")

def parse_intra_clocks(txt):
    """Intra Clock Table ⇒ {时钟名: 该行有几个数字列}。
       旁证用: 一个只出现在 Clock Summary、却不在 Intra 表里的时钟, 很可能**没驱动任何端点**
       (只改 Clock Summary 是骗过双域判据的最省事办法 ⇒ 必须有这条独立旁证)。"""
    body = _section(txt, "Intra Clock Table")
    if body is None:
        return None
    out = {}
    for ln in body.splitlines():
        t = ln.split()
        if len(t) < 2 or not re.match(r"^[-\d.]+$", t[1]):
            continue
        out[t[0]] = len(t) - 1
    return out

def parse_clock_summary(txt):
    """Clock Summary ⇒ [{name, period, freq}]; 名字由周期反查 (网名不硬编码)。"""
    body = _section(txt, "Clock Summary")
    if body is None:
        return None
    out = []
    for ln in body.splitlines():
        m = CLOCK_ROW.match(ln)
        if m:
            out.append({"name": m.group(1), "period": float(m.group(4)), "freq": float(m.group(5))})
    return out

# Check Type 可能 1~3 个词 ⇒ 用枚举而不是按列数切 (列宽由 Vivado 按内容自适应, 会变)
PW_ROW = re.compile(
    r"^(Min Period|Low Pulse Width|High Pulse Width|Min Low Pulse Width|Min High Pulse Width"
    r"|Max Skew|Recovery|Removal)\s+(\S+)\s+(\S+)\s+(\S+)\s+(" + NUM + r"|n/a)\s+(" + NUM + r"|n/a)"
    r"\s+(" + NUM + r"|n/a)\s+(\S+)\s+(\S+)\s*$")

def parse_pulse_width(txt):
    """所有 'Pulse Width Checks' 表 ⇒ (行列表, 表个数)。
       每行: 时钟 / 检查类型 / 库引脚 / 需求 / 实测 / 松弛 / 位置 / 引脚
    ⚠️ 分隔线 `-----` **既是**表头下的列线、也是表尾线 —— 第一版用 "遇到分隔线就收尾"
       把第二张表起头的那条列线当成表尾 ⇒ 整张表被静默跳过 (t6p4 的 16 条违例因此读成 0 条,
       看着就是 PASS)。判据自带的"与总表对账"把它抓出来了。现在按**当前表已解析行数**
       收尾 (cur_n) ⇒ 表头下的列线不会误收尾。"""
    rows, cur, cur_n, n_sec = [], None, 0, 0
    def fl(x):
        return None if x == "n/a" else float(x)
    for ln in txt.splitlines():
        if ln.strip() == "Pulse Width Checks":
            cur, cur_n, n_sec = {"clock": "?", "period": None}, 0, n_sec + 1
            continue
        if cur is None:
            continue
        m = re.match(r"^\s*Clock Name:\s*(\S+)", ln)
        if m:
            cur["clock"] = m.group(1)
            continue
        m = re.match(r"^\s*Period\(ns\):\s*(" + NUM + r")", ln)
        if m:
            cur["period"] = float(m.group(1))
            continue
        m = PW_ROW.match(ln)
        if m:
            rows.append({
                "clock": cur["clock"], "clock_period": cur["period"],
                "check": m.group(1), "lib_pin": m.group(3),
                "required": fl(m.group(5)), "actual": fl(m.group(6)),
                "slack": fl(m.group(7)), "location": m.group(8), "pin": m.group(9),
            })
            cur_n += 1
            continue
        if cur_n and re.match(r"^-{10,}\s*$", ln):
            cur = None
    return rows, n_sec

# =============================================================================
# 判据
# =============================================================================
def period_in(p, target):
    return p is not None and abs(p - target) <= target * TOL

def fmt_periods(ps):
    return ", ".join("%.3f" % p for p in sorted(set(ps)))

def criterion2(clocks, mode, intra):
    """返回 (verdict, 实测描述, 补充行列表)"""
    extra = []
    fam = sorted({c["period"] for c in clocks if FAMILY_LO <= c["period"] <= FAMILY_HI})
    def names_of(target):
        ns = sorted({c["name"] for c in clocks if period_in(c["period"], target)})
        if not ns:
            return "(无)"
        short = [n if len(n) <= 48 else n[:45] + "..." for n in ns[:4]]
        tail = "" if len(ns) <= 4 else " …(共 %d 个网名, 余略)" % len(ns)
        return ", ".join(short) + tail
    extra.append("  [时钟族自动发现] 周期落在 [%.1f, %.1f] ns 的时钟 (由周期反查网名):" % (FAMILY_LO, FAMILY_HI))
    extra.append("    ~%.3fns 族 (=%.2f MHz, 前端)     : %s" % (TARGET_FE, 1000.0 / TARGET_FE, names_of(TARGET_FE)))
    extra.append("    ~%.3fns 族 (=%.2f MHz, 数据面) : %s" % (TARGET_DP, 1000.0 / TARGET_DP, names_of(TARGET_DP)))
    extra.append("    该带内全部周期: %s" % (fmt_periods(fam) if fam else "(空)"))
    have_fe = any(period_in(p, TARGET_FE) for p in fam)
    have_dp = any(period_in(p, TARGET_DP) for p in fam)
    # ---- 旁证: 这些时钟真的在 Intra Clock Table 里有端点吗 (只改 Clock Summary 骗不过这一条) ----
    if intra is None:
        extra.append("    [WARN] 报告里没有 Intra Clock Table ⇒ 双域判据缺一条旁证 (只能靠 Clock Summary)")
    else:
        fam_names = sorted({c["name"] for c in clocks if FAMILY_LO <= c["period"] <= FAMILY_HI})
        miss = [n for n in fam_names if n not in intra and len(n) <= 48]
        if miss:
            extra.append("    [WARN] 下列 family 时钟**不在 Intra Clock Table 里** ⇒ 它们可能没驱动任何时序端点"
                         " (或报告结构不同): %s" % ", ".join(miss[:6]))
            extra.append("           ⚠️ 判据2 的 PASS 本就该由这条旁证背书 —— 若 P6b 报告里 6.400ns 域也有这个 WARN,"
                         " 说明它只是个被约束的空时钟, **不是数据面真跑在它上面**")
        elif fam_names:
            extra.append("    [旁证] family 时钟都在 Intra Clock Table 里有端点行 ⇒ 双域不是空约束 ✓")

    if mode == "single":
        return (NA, "报告被声明为单约束运行 --expect single (不判双域); 实见 family 周期: %s" % fmt_periods(fam),
                extra + ["    [N/A 理由] `--expect single` ⇒ 判据2 不适用 (P6b 验收请改用 `--expect dual`)"])
    if mode == "dual":
        if have_fe and have_dp:
            return (PASS, "~8.000ns 与 ~6.400ns 域都在", extra)
        miss = []
        if not have_fe:
            miss.append("缺 ~8.000ns 域 (前端 125MHz)")
        if not have_dp:
            miss.append("缺 ~6.400ns 域 (数据面 156.25MHz) —— 数据面**没搬到**新域")
        return (FAIL, "; ".join(miss) + " (实见 family 周期: %s)" % (fmt_periods(fam) or "空"), extra)
    # auto
    if have_fe and have_dp:
        return (PASS, "~8.000ns 与 ~6.400ns 域都在 (自动判定为双域报告, 判据生效)", extra)
    if len(fam) <= 1:
        extra.append("    [N/A 理由] auto: 该带内只有 %d 个周期 ⇒ 判定为**单域报告** ⇒ 判据2 不适用" % len(fam))
        extra.append("    ⚠️⚠️ **若这是 P6b 验收, 这个 N/A 会掩盖「数据面没搬到 156.25MHz」⇒ 必须 `--expect dual` 重跑, 届时本项 FAIL**")
        return (NA, "单域报告 (family 周期: %s)" % (fmt_periods(fam) or "空"), extra)
    return (FAIL, "该带内有 %d 个周期但既不齐 {~8.000, ~6.400}: %s" % (len(fam), fmt_periods(fam)), extra)

def criterion3(rows, dtm, n_sec):
    """Min-Period / Pulse-Width 违例; 显式点名 IDDRE1/C|CB 的 Min-Period。"""
    viol = [r for r in rows if r["slack"] is not None and r["slack"] < 0.0]
    # ---- 空读数 != 真 0 (本工具第一版真踩了这个坑, 见 parse_pulse_width 的注释) ----
    if n_sec > 0 and not rows:
        return False, [
            "  [FAIL] 判据3  报告里有 %d 张 'Pulse Width Checks' 表, 但**一行都解析不出来**"
            " ⇒ 解析失败 (格式变了?), 按最保守判 FAIL" % n_sec,
            "         (空读数 != 真 0 —— 绝不能因为「没解析到违例」就判 PASS)"]
    if dtm and dtm["pw_fail"] > 0 and not viol:
        return False, [
            "  [FAIL] 判据3  总表自报 TPWS Failing Endpoints=%d, 但本工具一条违例行都没找到"
            " ⇒ 两个证据互相矛盾, 按最保守判 FAIL" % dtm["pw_fail"],
            "         (要么解析漏了, 要么总表读错 —— 两者都得先查清)"]
    minper = [r for r in viol if r["check"] == "Min Period"]
    iddre = [r for r in minper if r["lib_pin"].startswith("IDDRE1/")]
    iddre_c_cb = [r for r in iddre if r["lib_pin"] in ("IDDRE1/C", "IDDRE1/CB")]
    skew_viol = [r for r in viol if r["check"] == "Max Skew"]
    marginal = [r for r in rows if r["slack"] is not None and r["slack"] == 0.0]
    zero_slack_iddre = [r for r in marginal if r["check"] == "Min Period" and r["lib_pin"].startswith("IDDRE1/")]

    lines = []
    # --- 显式点名的这一条 (闸 G 的旧账) ---
    lines.append("  [%s] 判据3a 判据=IDDRE1/C|CB Min-Period 违例数 | 期望=0 | 实测=%d"
                 % (PASS if not iddre_c_cb else FAIL, len(iddre_c_cb)))
    lines.append("         (闸 G = 整设计按 6.400ns 约束那次, 产生了这批 required=8.000ns 的"
                 " HDIO 器件上限违例; P6b 双约束下必须为 0)")
    # --- 总量 ---
    lines.append("  [%s] 判据3b 判据=Min-Period 违例总数 (含 OSERDESE3/CLK 等) | 期望=0 | 实测=%d"
                 % (PASS if not minper else FAIL, len(minper)))
    lines.append("  [%s] 判据3c 判据=Pulse-Width 违例总数 (Min Period + Low/High Pulse Width) | 期望=0 | 实测=%d"
                 % (PASS if not viol else FAIL, len(viol)))

    if viol:
        by_pin = {}
        for r in viol:
            by_pin.setdefault((r["check"], r["lib_pin"]), []).append(r)
        lines.append("         ↓ 逐类点名 (check / 库引脚 / 条数 / required / actual / slack):")
        for (ck, lp), rs in sorted(by_pin.items()):
            lines.append("           %-16s %-20s x%-3d required=%.3f actual=%.3f slack=%.3f  e.g. %s"
                         % (ck, lp, len(rs), rs[0]["required"], rs[0]["actual"], rs[0]["slack"], rs[0]["pin"]))
    if zero_slack_iddre:
        lines.append("  [WARN] 判据3d 有 %d 条 IDDRE1 Min-Period 的 slack **恰好 0.000** "
                     "(贴边, 不是违例, 但一点余量都没有)" % len(zero_slack_iddre))
    if skew_viol:
        lines.append("  [WARN] 另有 %d 条 **Max Skew** 负松弛 (不计入判据3; 单列出来别漏看)" % len(skew_viol))

    if dtm:
        vp = {r["pin"] for r in viol}
        if dtm["pw_fail"] == len(vp):
            lines.append("  [INFO] 与总表对账: 总表 TPWS Failing Endpoints=%d, 本工具点名的不同引脚数=%d ⇒ 一致"
                         % (dtm["pw_fail"], len(vp)))
        else:
            lines.append("  [WARN] 与总表对账不一致: 总表 TPWS Failing Endpoints=%d, 本工具点名的不同引脚数=%d"
                         " (报告格式可能变了 ⇒ 别只信一处)" % (dtm["pw_fail"], len(vp)))
    ok = (not viol) and (not iddre_c_cb)
    return ok, lines

def joint(wns, fail_cnt, label, unit="端点", wlabel="WNS"):
    """判据4: WNS 报告值 与 失败端点数=0 **同时**成立。单边成立一律 FAIL 并点名方向。"""
    ok_sign, ok_cnt = (wns is not None and wns >= 0.0), (fail_cnt == 0)
    if ok_sign and ok_cnt:
        return True, "%s=%+.3f 且失败%s=0 ⇒ 双边同时成立" % (wlabel, wns, unit)
    if wns is None:
        return False, "%s 解析不出来 (空读数 != 真 0) ⇒ 不许判 PASS" % wlabel
    if ok_sign and not ok_cnt:
        return False, "**%s=%+.3f 但失败%s=%d** ⇒ 不许判 PASS (正 %s 被局部违例掩盖; %s 侧有问题)" % (
            wlabel, wns, unit, fail_cnt, wlabel, label)
    if (not ok_sign) and ok_cnt:
        return False, "**%s=%+.3f 但失败%s=0** ⇒ 不许判 PASS (读数/解析可疑, 两个证据互相矛盾)" % (
            wlabel, wns, unit)
    return False, "%s=%+.3f 且失败%s=%d ⇒ 双边都不成立" % (wlabel, wns, unit, fail_cnt)

# =============================================================================
def main():
    ap = argparse.ArgumentParser(description="P6b 时序报告自动判据 (机器可判)")
    ap.add_argument("rpt", help="report_timing_summary 生成的 .rpt (text)")
    ap.add_argument("--expect", choices=("dual", "single", "auto"), default="auto",
                    help="判据2 的语义: dual=P6b 验收入口 (硬判双域) / single=单域历史报告 / auto=由内容推断 (默认)")
    args = ap.parse_args()

    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # 本工程坑: GBK 控制台下中文 print 会抛 → 退出码变 1 ⇒ 假 FAIL
    except Exception:
        pass

    path = os.path.abspath(args.rpt)
    print("#" * 100)
    print("# P6b 时序闸: %s" % path)
    if not os.path.exists(path):
        print("# [FATAL] 报告不存在 ⇒ FAIL (空读数 != 真 0)")
        return 2
    txt = read_text(path)
    hdr = parse_header(txt)
    print("# 溯源: %s | Design=%s | Device=%s | State=%s" % (hdr["tool"], hdr["design"], hdr["device"], hdr["state"]))
    print("#       生成时间: %s" % hdr["date"])
    print("# 判据2 语义: --expect %s%s" % (args.expect,
          "  (⭐ P6b 验收必须用 dual)" if args.expect != "dual" else "  (硬判双域)"))
    print("#" * 100)

    results = []   # (判据号, 判定, 单行描述)
    def rec(cid, verdict, desc):
        results.append((cid, verdict, desc))

    # ---------- 解析总表 ----------
    dtm = parse_design_timing_summary(txt)
    if dtm is None:
        print("\n[FATAL] 解析不出 Design Timing Summary (报告没生成? 格式变了?)")
        print("        ⇒ 判据全部无法成立, 判 FAIL (绝不因解析失败而默认成 0)")
        return 2
    clocks = parse_clock_summary(txt)
    if clocks is None:
        print("\n[FATAL] 解析不出 Clock Summary ⇒ 判据2 (双域发现) 无从谈起")
        return 2
    pw_rows, n_pw_sec = parse_pulse_width(txt)
    verdict = parse_verdict(txt)

    # ---------- 判据 2 (先打时钟域自动发现的表, 后面判据都要看它) ----------
    v2, t2, extra2 = criterion2(clocks, args.expect, parse_intra_clocks(txt))
    print("")
    for ln in extra2:
        print(ln)
    print("")
    print("  [%s] 判据2 判据=双域存在性 (前端 ~8.000ns + 数据面 ~6.400ns) | 期望=%s | 实测=%s"
          % (v2, "两个域都在" if args.expect != "single" else "不适用", t2))
    rec(2, v2, t2)

    # ---------- 判据 1 ----------
    print("")
    print("  [%s] 判据1a 判据=setup 失败端点数 | 期望=0 | 实测=%d / %d 端点"
          % (PASS if dtm["setup_fail"] == 0 else FAIL, dtm["setup_fail"], dtm["setup_tot"]))
    rec("1a", PASS if dtm["setup_fail"] == 0 else FAIL, "setup 失败端点 %d" % dtm["setup_fail"])
    print("  [%s] 判据1b 判据=hold  失败端点数 | 期望=0 | 实测=%d / %d 端点"
          % (PASS if dtm["hold_fail"] == 0 else FAIL, dtm["hold_fail"], dtm["hold_tot"]))
    rec("1b", PASS if dtm["hold_fail"] == 0 else FAIL, "hold 失败端点 %d" % dtm["hold_fail"])

    # ---------- 判据 4 (WNS 与端点数的**联合**判据) ----------
    print("")
    ok4s, d4s = joint(dtm["wns"], dtm["setup_fail"], "setup")
    print("  [%s] 判据4a 判据=setup WNS 与失败端点数**联合** | 期望=两者同时成立 | 实测=%s" % (PASS if ok4s else FAIL, d4s))
    rec("4a", PASS if ok4s else FAIL, d4s)
    ok4h, d4h = joint(dtm["whs"], dtm["hold_fail"], "hold")
    print("  [%s] 判据4b 判据=hold  WHS 与失败端点数**联合** | 期望=两者同时成立 | 实测=%s" % (PASS if ok4h else FAIL, d4h))
    rec("4b", PASS if ok4h else FAIL, d4h)
    # pulse-width 的 WNS/WPWS 也用同一把尺 (负数即失败; 端点数为 0 而 WPWS<0 是矛盾读数)
    ok4p, d4p = joint(dtm["wpws"], dtm["pw_fail"], "pulse-width", wlabel="WPWS")
    print("  [%s] 判据4c 判据=WPWS 与失败端点数**联合** | 期望=两者同时成立 | 实测=%s" % (PASS if ok4p else FAIL, d4p))
    rec("4c", PASS if ok4p else FAIL, d4p)

    # ---------- 判据 3 ----------
    print("")
    ok3, lines3 = criterion3(pw_rows, dtm, n_pw_sec)
    for ln in lines3:
        print(ln)
    rec("3", PASS if ok3 else FAIL, "Pulse-Width/Min-Period 违例 %d 条 (解析 %d 张表 / %d 行)" %
        (len([r for r in pw_rows if r["slack"] is not None and r["slack"] < 0.0]), n_pw_sec, len(pw_rows)))

    # ---------- 判据 5 ----------
    print("")
    if verdict == "met":
        print("  [PASS] 判据5 判据=报告自述总判 | 期望='All user specified timing constraints are met.' | 实测=约束全满足")
        rec(5, PASS, "报告自述 constraints met")
    elif verdict == "not_met":
        print("  [FAIL] 判据5 判据=报告自述总判 | 期望='All user specified timing constraints are met.' | 实测='Timing constraints are not met.'")
        rec(5, FAIL, "报告自述 constraints NOT met")
    elif verdict == "both":
        print("  [FAIL] 判据5 判据=报告自述总判 | 期望=只有一个总判句 | 实测=**两句同时出现** (报告被拼接/截断过?) ⇒ 按最保守判 FAIL")
        rec(5, FAIL, "总判句同时出现 met 与 not met")
    else:
        print("  [FAIL] 判据5 判据=报告自述总判 | 期望=能找到总判句 | 实测=**找不到总判句** (报告不完整) ⇒ FAIL")
        rec(5, FAIL, "报告里没有总判句")

    # ---------- 汇总 ----------
    n_fail = sum(1 for _, v, _ in results if v == FAIL)
    n_na = sum(1 for _, v, _ in results if v == NA)
    n_pass = sum(1 for _, v, _ in results if v == PASS)
    print("")
    print("-" * 100)
    print("汇总 (按判据号):")
    for cid, v, desc in sorted(results, key=lambda r: str(r[0])):
        print("  [%-4s] 判据%-3s %s" % (v, cid, desc))
    print("-" * 100)
    if n_fail:
        print("TIMING-FAIL: FAIL=%d PASS=%d N/A=%d ⇒ **上板前必须先解决** (违例的接收端可能正好在读数通路上)" % (n_fail, n_pass, n_na))
        return 1
    if n_na and args.expect == "auto":
        print("TIMING-OK: FAIL=0 PASS=%d N/A=%d" % (n_pass, n_na))
        print("⚠️ 有 N/A 项 (多为判据2 的单域豁免)。**P6b 验收请在 `--expect dual` 下复跑**, 否则这个 OK 不能当结论。")
        return 0
    print("TIMING-OK: FAIL=0 PASS=%d N/A=%d" % (n_pass, n_na))
    return 0

if __name__ == "__main__":
    sys.exit(main())
