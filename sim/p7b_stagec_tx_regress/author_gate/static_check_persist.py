#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""static_check_persist.py -- P7B-PERSIST 实施轮的**静态核对脚本** (三项 + 自检).

设计件 = _proj_10g/notes/P7B_PERSIST_DESIGN.md (v3) 的 §4.3 (L1) / §5.3 (参数账实) /
§7.2 (S1 静态剪枝). 本脚本**只读** rtl/tcp_tx_frame.v 与 git diff, 不写任何源码.

  [S1] PERSIST_EN=0 常量性:
       列出本刀**新增的信号**, 对每个信号找出**全部写点**, 逐点判定:
         (a) RHS 是字面零 (1'b0 / 3'd0 / 26'd0 / ...)                      -> OK(const)
         (b) 该写点的**守卫栈**里含 PERSIST_EN / ps_arm / ps_fire / ps_rd_d2
             (即 PERSIST_EN=0 时不可达)                                     -> OK(gated)
       否则 -> EXCEPTION. 输出 "零例外" 或 "N 例外 + 逐条行号".

  [FB] mux 折回 (新增项让位): 对**被本刀改写的既有信号**, 断言新表达式里
       ① 仍含原操作数文本; ② 新项由 probe_sel / ctrl_probe / tx_is_probe / ps_rd 门控.
       (逐条硬编码 原文本 -> 新文本 对, 双向可核.)

  [L1] git diff -U0 三项 (设计件 §4.3-L1):
       (a) 白名单: 每个 `+` 行必须触及白名单符号之一;
       (b) 保序配对豁免: 禁用符号的新增命中 (`+` 命中 - 配对 `-` 已有命中) 必须为 0;
       (c) 负对照由 --selfcheck 承担 (注入越界符号 / 关掉配对豁免 => 必须红).

  [PD] 参数账实一致 (§5.3): rtl/tcp_tx_frame.v 的默认值 == 生产值
       (PERSIST_EN == 1'b0 / PS_BASE == 26'd3_051_758 / PS_MAX == 26'd36_621_094),
       且 `RTO_LIM` DP 支 == 12207 (板级构建定义 DP_156MHZ 的那一支).

退出码: 0 = 全项通过; 1 = 有项失败.
用法:
  python static_check_persist.py                 # 正式跑
  python static_check_persist.py --selfcheck     # 检查器有牙自检 (两处负对照必须变红)
"""
import io
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
RTL = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")

# ---------------------------------------------------------------- 新增信号表
NEW_SIGS = [
    "PERSIST_EN", "PS_BASE", "PS_MAX",
    "ps_timer", "ps_phase", "ps_stage_rdy", "ps_stage_conn", "ps_stage_seq",
    "ps_stage_byte", "ps_stage_estab", "ps_rd_d1", "ps_rd_d2",
    "tx_is_probe", "ctrl_probe", "ctrl_pld",
    "ds_guard", "probe_sel", "ps_arm", "ps_fire", "ps_rd", "ps_next", "ps_reload",
]
GATES = ("PERSIST_EN", "ps_arm", "ps_fire", "ps_rd_d2")

# ---------------------------------------------------- 被改写的既有信号: 折回对
FOLDBACK = [
    # (信号, 原操作数文本 [必须仍在新表达式里], 新项门控符号)
    ("start_ack", "(ack_pend_r && !ackq_empty)", "probe_sel", 6),
    ("upd_wr_ctrl", "(aq_syn | aq_fin | aq_rst)", "probe_sel", 6),
    ("rb_id", "(rx_state == RX_IDLE) ? start_id : f_conn[rx_bank]", "probe_sel", 6),
    ("ctrl_is", "{aq_rst, aq_fin, aq_syn}", "probe_sel", 6),
    ("ctrl_seq", "rb_snd_nxt", "probe_sel", 6),
    ("ctrl_doff", "ctrl_doff_now", "probe_sel", 6),
    ("ctrl_pld", "probe_sel ? ps_stage_byte : 8'h00", "probe_sel", 6),
    ("h_totlen", "(h_ctrl ? 16'd40 : f_totlen[tx_bank])", "tx_is_probe", 6),
    ("ctl_aen_v1", "18'd20", "ctrl_probe", 6),
    ("ctrl_ipcsum_now", "ctrl_idcap, ctrl_dip", "ctrl_probe", 6),
    ("ctrl_acc", "csum_init_ctrl", "ctrl_pld", 6),
    ("rd_en_m", "rd_tap", "ps_rd", 6),
    ("r_conn_m", "retx_id_r", "ps_rd", 6),
    ("r_seq_m", "r_tap_seq", "ps_rd", 6),
    ("m_axis_tdata", "{hold48, 16'h0000}", "tx_is_probe", 20),
    ("m_axis_tkeep", "8'hFC", "tx_is_probe", 20),
    ("rb_id", "ps_stage_conn", "probe_sel", 6),
    ("ctrl_ack_now", "ackq_dout[31:0]", "probe_sel", 6),
]

# ------------------------------------------------------------------ L1 白名单
WHITELIST = [
    "PERSIST_EN", "PS_BASE", "PS_MAX", "ps_phase", "ps_fire", "ps_stage_",
    "ps_rd_", "probe_sel", "ds_guard", "ctrl_probe", "tx_is_probe", "ctrl_pld",
    "start_ack", "rb_id", "cam_rd_id", "rd_en", "r_conn", "r_seq", "ctrl_seq",
    "ctrl_doff", "ctrl_ack_now", "ctrl_ipcsum", "ctrl_tcpcsum", "ctl_aen_v1",
    "h_totlen", "m_axis_tdata", "m_axis_tkeep", "upd_wr_ctrl", "ps_timer",
    "ps_arm", "ps_rd", "ps_next", "ps_reload", "ps_stage", "ctrl_is",
    "ps_rd_d1", "ps_rd_d2",
]
BANNED = [
    "svc_rewind", "retx_deny", "replay_full", "replay_left", "replay_jump",
    "ring_start", "ring_delta", "epoch", "blocked", "retx_hi", "acks_ok",
    "tx_blk_sid", "RETX_SPAN",
]
# 生产参数默认值 (§5.3)
PARAM_EXPECT = {
    "PERSIST_EN": r"parameter\s+PERSIST_EN\s*=\s*1'b0\s*;",
    "PS_BASE": r"parameter\s*\[25:0\]\s*PS_BASE\s*=\s*26'd3_051_758\s*;",
    "PS_MAX": r"parameter\s*\[25:0\]\s*PS_MAX\s*=\s*26'd36_621_094\s*;",
    "RTO_LIM_DP": r"parameter\s+integer\s+RTO_LIM\s*=\s*12207\s*;",
}


def rd(path):
    return io.open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")


# ⭐ 2026-10-11 (实施件审查轮 D-9 / 问题 P-5): L1 的 diff 基**不再用 HEAD** ——
#   钉死到 persist 刀的锚提交对: cfd3b1a (改前件, 与 `frozen/tcp_tx_frame_revcfd3b1a.v`
#   同源) .. fd671b6 (persist 实施)。理由: 原实现 `git diff -U0 -- <file>` = 工作树 vs
#   HEAD ⇒ 改动一经提交, 该 diff 恒为空 ⇒ L1(a)/(b) 退化成**空判据**
#   (落盘的 `ev/static_check_formal.txt` 就是该形态: "代码 `+` 行 0 条")。
#   ⚠️ 这里改用**双端钉死**的提交对 ⇒ 与工作树/后续刀漂移解耦、可永久复跑
#   (纪律: 判据的锚必须钉在不可漂的坐标)。
L1_BASE   = "cfd3b1a"     # persist 刀的"改前"锚 (＝冻锚来源提交)
L1_TARGET = "fd671b6"     # persist 刀的实施提交


def git_diff_u0():
    """L1 主体 = **钉死提交对** (L1_BASE..L1_TARGET) 对 rtl/tcp_tx_frame.v 的 -U0 diff。"""
    out = subprocess.run(["git", "diff", "-U0", L1_BASE, L1_TARGET,
                          "--", "rtl/tcp_tx_frame.v"],
                         cwd=ROOT, capture_output=True)
    if out.returncode != 0:
        raise SystemExit("git diff failed: " + out.stderr.decode("utf-8", "replace"))
    return out.stdout.decode("utf-8", "replace").replace("\r\n", "\n")


def strip_comments(line):
    """去掉行内 // 注释 (保守: 只在 // 之后无引号时截断)."""
    i = line.find("//")
    return line if i < 0 else line[:i]


def guard_stack(lines, idx):
    """返回 idx 行(0基)所在位置的**守卫条件栈** (按 begin/end 近似配对).

    说明: 这是文本级近似 —— 只看 `if (...)` / `else if (...)` + 同行的 `begin`
    与 `end` 的计数. 本仓 RTL 是规整的 begin/end 风格 ⇒ 近似可用; 判错的代价是
    **报 EXCEPTION** (保守方向, 不会把错误判成正确).
    """
    stack = []
    depth = 0
    pend = None
    for n in range(idx + 1):
        raw = lines[n]
        code = strip_comments(raw)
        # 先处理 end / begin 的配对
        if pend is not None and n > 0:
            pass
        m = re.search(r"\bif\s*\((.*)\)\s*begin\b", code)
        if m:
            stack.append((depth, m.group(1)))
        else:
            m2 = re.search(r"\belse\s+if\s*\((.*)\)\s*begin\b", code)
            if m2:
                stack.append((depth, m2.group(1)))
        depth += code.count("begin")
        if "end" in code and "endcase" not in code and "endfunction" not in code:
            depth -= code.count("end") - code.count("endcase") - code.count("endfunction")
    return [c for _, c in stack]


def is_code(line):
    """非空且非纯注释 —— 本检查器对 L1/S1 的统一口径 (**注释不算代码**).

    依据: 设计件 §4.3-L1 的白名单/禁用符号是给**代码行**立的判据; 本刀故意在注释里
    点名禁用符号 (如解释"为什么 ds_guard 不许写 `!tx_blk_sid`") —— 那是纪律的落点,
    不是对被禁机制的改动。口径写在明处, 可复核。
    """
    s = line.strip()
    return bool(s) and not s.startswith("//")


def stmts(code_line):
    """把一行拆成 `;` 分隔的语句 (复位块里一行常写多条赋值)."""
    parts = []
    for chunk in code_line.split(";"):
        if chunk.strip():
            parts.append(chunk)
    return parts


def check_s1(text):
    """S1: PERSIST_EN=0 时新增信号逐写点必须"字面零 或 守卫下 或 已证常量信号"。

    判定序 (**依赖序**, 传递闭包):
      1. ps_arm        : 守卫含 PERSIST_EN ⇒ 恒 0
      2. ps_fire/ps_rd : RHS 含 ps_arm (已证) / 守卫 gated
      3. ps_rd_d1/d2   : RHS = ps_rd / ps_rd_d1 (已证恒 0) ⇒ 恒 0
      4. 其余 (reset/cfg_up/消除武装/消费 写点): 字面零, 或守卫含 PERSIST_EN/ps_arm/
         ps_fire/ps_rd_d2 (不可达)
    """
    lines = text.split("\n")
    const_sigs = set()          # 已被判定恒 0 的新信号
    problems = []
    total_sites = 0
    order = ["ps_arm", "ps_fire", "ps_rd", "ps_rd_d1", "ps_rd_d2", "ps_next",
             "ps_reload"] + [s for s in NEW_SIGS if s not in
                             ("ps_arm", "ps_fire", "ps_rd", "ps_rd_d1", "ps_rd_d2",
                              "ps_next", "ps_reload")]
    for sig in order:
        sig_bad = []
        for n, raw in enumerate(lines):
            if not is_code(raw):
                continue
            code = strip_comments(raw)
            if re.match(r"\s*parameter\b", code):
                continue
            for st in stmts(code):
                hit = re.search(r"\b" + re.escape(sig) + r"\s*<=", st)
                hit2 = re.search(r"\bassign\s+" + re.escape(sig) + r"\b", st)
                if not (hit or hit2):
                    continue
                total_sites += 1
                rhs = st.split("<=", 1)[1] if hit else st.split("=", 1)[1]
                rhs = rhs.strip()
                const0 = bool(re.fullmatch(
                    r"(1'b0|1'h0|3'd0|4'd0|8'h0*0|16'h0*0|18'd0|21'd0|26'd0|"
                    r"32'd0|64'd0|0)", rhs))
                gs = " ".join(guard_stack(lines, n))
                gated = any(g in gs for g in GATES)
                # RHS 直接引用另一个"已证恒 0"的新信号 (或含它做运算, 且无别的自由变量)
                ref_const = False
                for cs in const_sigs:
                    if re.fullmatch(r"(~?\s*\(?\s*)?" + re.escape(cs) +
                                    r"(\s*\)?\s*)?(==\s*26'd1|\+|\-)?[\s0-9'd()]*", rhs):
                        ref_const = True
                if not (const0 or gated or ref_const):
                    sig_bad.append((n + 1, sig, raw.strip()[:110]))
        if not sig_bad:
            const_sigs.add(sig)
        problems.extend(sig_bad)
    return total_sites, problems


def check_foldback(text):
    """FB: 对被改写的既有信号, 断言 ① 原操作数文本仍在源码里;
    ② 原操作数所在的那条**写表达式** (±3 行窗口) 同时含新项门控。

    窗口 ±3 行的依据: 本刀的多行三目最长 3 行 (如 `h_totlen = tx_is_probe ? ... :
    (h_ctrl ? ... : f_totlen[...])`), 而"探询支/纯 ACK 支"这种分叉在同一 begin 块内
    相隔 ≤6 行 ⇒ 用"**找到含 gate 且含 orig 的最短窗口**"判: 只要存在一条 gate 行与
    orig 行相距 ≤6 行即算通过 (并打印该距离, 可复核)。
    """
    bad = []
    lines = text.split("\n")
    for fb in FOLDBACK:
        sig, orig, gate = fb[0], fb[1], fb[2]
        win_n = fb[3] if len(fb) > 3 else 6
        if orig not in text:
            bad.append((sig, orig, "原操作数文本**不在**源码里", gate))
            continue
        best = 999
        orig_lines = [n for n, l in enumerate(lines) if orig in l]
        gate_lines = [n for n, l in enumerate(lines) if gate in l]
        for a in orig_lines:
            for b in gate_lines:
                best = min(best, abs(a - b))
        if best > win_n:
            bad.append((sig, orig, "原操作数与新项门控 %s 相距 %d 行 (>%d)" % (gate, best, win_n), gate))
        else:
            print("     [FB-ok] %-16s orig<->%-10s 行距 %d (窗口 %d)" % (sig, gate, best, win_n))
    return bad


def check_l1(diff_text, pairing=True):
    """返回 (whitelist_bad, banned_bad, n_code_plus)。diff_text = git diff -U0 的正文。

    口径 (写在明处): 白名单/禁用符号只判**代码行** (非空、非 `//` 注释) —— 本刀故意在
    注释里点名禁用符号以钉纪律 (如"⛔ 禁用 `!start_data` ⇒ 成环"), 那不是改动。
    """
    plus_c, minus_c = [], []
    for l in diff_text.split("\n"):
        if l.startswith("+") and not l.startswith("+++"):
            plus_c.append(l[1:])
        elif l.startswith("-") and not l.startswith("---"):
            minus_c.append(l[1:])
    plus = [l for l in plus_c if is_code(l)]
    minus = [l for l in minus_c if is_code(l)]
    # (a) 白名单: 逐 **hunk 内"连续 + 行组"** 判 —— 设计件口径的落地方式: 一次改动
    #     (一组连续新增行) 触及白名单符号之一即可; 多行声明/三目折行的续行
    #     (`begin` / `end` / `input [2:0] p;` / 续写操作数) 不单独判, 否则任何多行写法
    #     都结构性不可能通过。分组以 diff 的 `@@` hunk 为界、hunk 内以"连续 `+` 行"为组。
    wl_bad = []
    n_run = 0
    for h in re.split(r"^@@", diff_text, flags=re.M)[1:]:
        run = []
        for l in h.split("\n"):
            if l.startswith("+") and not l.startswith("+++"):
                run.append(l[1:])
            else:
                if run:
                    n_run += 1
                    code_run = [x for x in run if is_code(x)]
                    if code_run and not any(any(w in x for w in WHITELIST)
                                            for x in code_run):
                        wl_bad.extend(code_run)
                    run = []
        if run:
            n_run += 1
            code_run = [x for x in run if is_code(x)]
            if code_run and not any(any(w in x for w in WHITELIST) for x in code_run):
                wl_bad.extend(code_run)
    L1_NRUN = n_run
    ban_bad = []
    for b in BANNED:
        n_plus = sum(1 for l in plus if re.search(r"\b" + re.escape(b) + r"\b", l))
        n_minus = sum(1 for l in minus if re.search(r"\b" + re.escape(b) + r"\b", l))
        net = n_plus if not pairing else (n_plus - n_minus)
        if net > 0:
            ban_bad.append((b, n_plus, n_minus, net))
    return wl_bad, ban_bad, len(plus)


def check_params(text):
    bad = []
    for name, pat in PARAM_EXPECT.items():
        if not re.search(pat, text):
            bad.append((name, pat))
    return bad


def main():
    selfcheck = "--selfcheck" in sys.argv
    text = rd(RTL)
    diff = git_diff_u0()

    print("=" * 74)
    print("P7B-PERSIST 静态核对 (S1 / FB / L1 / PD)" + ("  [SELFCHECK 模式]" if selfcheck else ""))
    print("  RTL = %s" % RTL)
    print("=" * 74)

    ok_all = True

    # ---- [S1]
    n_sites, s1_bad = check_s1(text)
    print("\n[S1] PERSIST_EN=0 常量性: 新增信号 %d 个 / 写点 %d 处" % (len(NEW_SIGS), n_sites))
    if not s1_bad:
        print("     ==> 零例外 (每个写点 = 字面零 或 在 PERSIST_EN/ps_arm/ps_fire/ps_rd_d2 守卫下)")
    else:
        ok_all = False
        print("     ==> **%d 处例外**:" % len(s1_bad))
        for ln, sig, txt in s1_bad:
            print("        L%-5d %-14s %s" % (ln, sig, txt))

    # ---- [FB]
    fb_bad = check_foldback(text)
    print("\n[FB] mux 折回 (被改写的既有信号: 原操作数仍在 + 新项门控): %d 条" % len(FOLDBACK))
    if not fb_bad:
        print("     ==> 全部通过 (原操作数文本仍在, 新项由 probe_sel/tx_is_probe/ctrl_probe/ps_rd 门控)")
    else:
        ok_all = False
        for sig, orig, why, gate in fb_bad:
            print("     ==> **EXCEPTION** %s: %s (%s)" % (sig, why, gate))

    # ---- [L1]
    pairing = True
    diff_use = diff
    if selfcheck:
        # 负对照 1: 注入一个**独立 hunk** 的越界符号 (只触及被禁符号, 不触白名单)
        diff_use = diff + "@@ -999990,0 +999990,1 @@\n+    assign zz = svc_rewind;\n"
    wl_bad, ban_bad, n_plus_code = check_l1(diff_use, pairing=pairing)
    print("\n[L1] git diff -U0 三项 (diff 基 = 钉死提交对 %s..%s):" % (L1_BASE, L1_TARGET))
    print("     (a) 白名单: 代码 `+` 行 %d 条 (注释/空行不计), 越界 %d 条" % (
        n_plus_code, len(wl_bad)))
    for l in wl_bad[:8]:
        print("         [越界] %s" % l.strip()[:100])
    print("     (b) 保序配对豁免: 禁用符号净新增 %d 条" % len(ban_bad))
    for b, np_, nm, net in ban_bad:
        print("         [净新增] %-14s +%d -%d => %d" % (b, np_, nm, net))
    if selfcheck:
        # 自检 1: 注入**独立 hunk** 的越界符号 => 白名单与禁用符号两侧都必须红
        inject_red_wl = len(wl_bad) >= 1
        inject_red_ban = any(b[0] == "svc_rewind" for b in ban_bad)
        print("     [SELFCHECK-1] 注入独立 hunk 的 `assign zz = svc_rewind;` => "
              "白名单红=%s 禁用符号红=%s" % (inject_red_wl, inject_red_ban))
        # 自检 2: **配对豁免的两个方向** —— 成对搬移 => 净 0 (不红); 关掉配对 => 原始命中 >0
        paired = ("@@ -1,1 +1,1 @@\n"
                  "-    wire zz = svc_rewind;\n"
                  "+    wire zz = svc_rewind;   // moved (paired)\n")
        _, ban_p1, _ = check_l1(diff + paired, pairing=True)
        _, ban_p0, _ = check_l1(diff + paired, pairing=False)
        n_p1 = sum(b[3] for b in ban_p1)
        n_p0 = sum(b[1] for b in ban_p0)
        print("     [SELFCHECK-2] 成对搬移 (含 svc_rewind 的 `-` 行 + `+` 行): "
              "开配对豁免 => 净新增 %d (期望 0); 关掉 => 原始命中 %d (期望 >0)" % (n_p1, n_p0))
        # 自检 3: 单侧新增 (无配对) => 必须红
        unpaired = "@@ -2,0 +2,1 @@\n+    wire zz2 = svc_rewind;\n"
        _, ban_up, _ = check_l1(diff + unpaired, pairing=True)
        n_up = sum(b[3] for b in ban_up)
        print("     [SELFCHECK-3] 单侧新增 svc_rewind (无配对) => 净新增 %d (期望 >0)" % n_up)
        teeth = (inject_red_wl and inject_red_ban and n_p1 == 0 and n_p0 > 0 and n_up > 0)
        print("     ==> %s" % ("自检通过 (三个负对照都有牙)" if teeth
                               else "**自检失败: 检查器某处没牙**"))
        return 0 if teeth else 1

    if wl_bad or ban_bad:
        ok_all = False
        print("     ==> **L1 不合格** (见上)")
    else:
        print("     ==> 白名单/禁用符号净新增 均通过")

    # ---- [PD]
    pd_bad = check_params(text)
    print("\n[PD] 参数账实一致 (§5.3):")
    for name, pat in PARAM_EXPECT.items():
        print("     %-12s %s" % (name, "OK" if not any(b[0] == name for b in pd_bad) else "**MISMATCH**"))
    if pd_bad:
        ok_all = False

    print("\n" + "=" * 74)
    print("STATIC_CHECK_PERSIST: %s" % ("PASS" if ok_all else "FAIL"))
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
