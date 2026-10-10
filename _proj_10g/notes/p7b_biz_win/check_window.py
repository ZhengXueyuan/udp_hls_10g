#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_window.py -- P7B-BIZ 快照窗口的**静态结构核对** (不需要 IP, 不跑 Vivado 构建)

为什么需要它 (与 tb_biz_win.v 互补, 覆盖面不重叠):
  · tb_biz_win.v 例化 axi_regs, 管"地址 <-> 字"那一半 (读侧译码/位宽/边界);
  · 本脚本管**另一半**: wrapper 里 `snap_dout_all` 的**装配映射**
    (项数 / 顺序 / 槽号 / 旧字是否移位 / 拼接各项是否已声明)。
  · xelab/synth 抓不到这一类: 拼接少一项 => 高位悬空, 顺序错 => 读出"另一个字的正确值",
    两种都是**合法 Verilog** => lint 全程沉默 (本工程踩过两次, 见 wrapper_p4.v 的扩窗注释)。
  · 实测 (本文件自带负对照): wrapper 的拼接里写一个**未声明的网名**, xvlog **一个字都不打印**
    (合法隐式网) => 第 7 项 (declared-before-use) 是这一面唯一的自动化守卫。

判据 (每一条都对着一个真实踩过的缺陷):
  1  SNAP_NW_P6E 与 snap_dout_all 的**项数恰好相等** (少一项 => 高位悬空 X; 多一项 => 截断)
  2  最右一项必须是 `snap_dout` (snap_seq 的 36 字), 其余项数 = NW-36
  3  束宽等式: FE14 + DP22 + P7BFE3 + (P7BDP-4 占位) + TX4 == SNAP_NW_P6E
  4  * **旧字一个都没移位**: 与 `git show HEAD:board/wrapper_p4.v` 的装配项**逐项比对**,
     旧项必须原封不动地出现在新表的**尾部** (新增项只能落在 MSB 端)
  5  * 新增 6 项落在**最上面**(MSB), 且槽号 <-> 字号的映射与 `p7bdp_din` 的显式 assign 一致
  6  `p7bdp_din` 的驱动项数 = SNAP_P7BDP_NW (generate 12 项 + 显式 assign 6 项)
  7  * 装配里出现的**每个标识符都已声明且声明在使用之前** (xvlog 对隐式网沉默)
  8  译码位宽 vs 回绕红线: `ar_word` 装得下 `(0x20+4*NW)>>2`; `snap_base` 装得下 `(NW-1)<<5`
  9/10 跨文件一致性 (W56 / 两个 slow_*_adp 的 stat_fifo_ovf)
  11 (2026-10-10) W63/W64 = app_pattern 两个停滞计数器: 端口 <-> 接线 <-> 快照字 三者齐

用法:  python check_window.py [--repo <repo>] [--mutate none|drop|swap|declpatho]
退出码: 0 = 全过 / 1 = 有判据 FAIL
"""
from __future__ import print_function
import io, os, re, subprocess, sys, argparse

FAILS = []
PASSES = []
INFO = []


def ck(cond, name, detail=""):
    tag = "[PASS]" if cond else "[FAIL]"
    (PASSES if cond else FAILS).append(name)
    print("  %s %s %s" % (tag, name, detail))


def info(name, detail=""):
    """非判据的说明行 —— **不计入 PASS/FAIL 计数**。

    为什么要有它 (2026-10-10): 原先这里有一行占位说明写成 `ck(True, "...")`, 于是它
    **恒 PASS 且被计进 `PASS=` 总数** ⇒ 报告里的 PASS 数里混着"恒真"的行 —— 本工程最忌
    "空判据被当判据"(全局经验 §六 同族: 判据总数里不许有无判别力的行)。"""
    INFO.append(name)
    print("  [INFO] %s %s" % (name, detail))


def read(p):
    return io.open(p, encoding="utf-8", newline="").read()


def split_top_items(text):
    """把 `{ a, b, ... }` 的内容按**顶层逗号**切成项 (括号/花括号内不切)."""
    items, depth, cur = [], 0, ""
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            items.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        items.append(cur.strip())
    return items


def grab_concat(src, lhs_regex):
    """抓 `... = { ... };` 的拼接内容 (从 `=` 后的第一个 `{` 配平到对应 `}`)."""
    m = re.search(lhs_regex, src)
    if not m:
        return None, None
    i = src.index("{", m.end() - 1)
    depth, j = 0, i
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    return src[i + 1:j], m


def code_of(item):
    """去掉行注释, 只留表达式 (比对时用)."""
    return re.sub(r"//.*", "", item).strip()


def main():
    if hasattr(sys.stdout, "reconfigure"):        # 中文/符号在 GBK 控制台下会抛 UnicodeEncodeError
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..")))
    ap.add_argument("--mutate", default="none", choices=["none", "drop", "swap", "declpatho"])
    a = ap.parse_args()
    repo, mut = a.repo, a.mutate
    wpath = os.path.join(repo, "board", "wrapper_p4.v")
    apath = os.path.join(repo, "_proj_pcie", "rtl", "axi_regs.v")
    print("=== check_window: P7B-BIZ 快照装配静态核对 (repo=%s, mutate=%s) ===" % (repo, mut))
    src0 = read(wpath)
    # ⚠️ 变异必须**在提取之前**做 (第一版把 declpatho 放在提取之后 ⇒ 改了个没被读的副本,
    #    负对照静默通过 = 假 PASS —— 这正是本工程最忌讳的"无声失效")
    if mut == "declpatho":
        src0 = src0.replace("p7bdp_dout[17*32 +: 32],   // W56", "biz_w56_undeclared_typo,   // W56")
        print("       [mutate=declpatho] 装配里把一个已声明网名换成未声明的拼写")

    # ---------- 判据 1: 项数 == SNAP_NW_P6E ----------
    m = re.search(r"localparam\s+SNAP_NW_P6E\s*=\s*(\d+)", src0)
    ck(m is not None, "1a SNAP_NW_P6E 声明存在")
    NW = int(m.group(1))
    print("       SNAP_NW_P6E = %d" % NW)
    # 束宽 localparam (先取: 后面的"逐项字数"换算要用它们)
    def lp(name):
        mm = re.search(r"localparam\s+%s\s*=\s*(\d+)" % name, src0)
        return int(mm.group(1)) if mm else None

    fe, dp, pfe, pdp, tx = (lp("SNAP_FE_NW"), lp("SNAP_DP_NW"), lp("SNAP_P7BFE_NW"),
                            lp("SNAP_P7BDP_NW"), lp("SNAP_TX_NW"))

    body_raw, _ = grab_concat(src0, r"wire\s*\[SNAP_NW_P6E\*32-1:0\]\s*snap_dout_all\s*=")
    ck(body_raw is not None, "1b snap_dout_all 拼接存在")
    # ⚠️ **先去注释再切项**: 注释里有**不配对的圆括号** (如 `(padrem 类回归的守卫)`), 而本切分器
    #     按 `()[]{}` 计深度 ⇒ 不去注释会把深度带偏, 只切出前 22 项 (第一版的错, 症状 = 22 ≠ 57)。
    #     注释不参与结构 ⇒ 先剥掉是正确做法, 不是权宜。
    body = re.sub(r"//[^\n]*", "", body_raw)
    items = split_top_items(body)

    # 负对照/变异 (全在内存里做 -> 不改工作区)
    if mut == "drop":
        items = items[:-1]
        print("       [mutate=drop] 去掉最右一项 (模拟'少一项')")
    elif mut == "swap":
        items[0], items[1] = items[1], items[0]
        print("       [mutate=swap] 交换最上面两项 (模拟'新增字错位')")
    elif mut == "declpatho":
        pass    # 已在上面 (提取之前) 做过
    # 原句 (恒 PASS 的占位行, 会被计进 PASS= 总数 ⇒ 2026-10-10 改 INFO, 判据语义零改动):
    #   ck(True, "1x (下一条按'总字数'判, 不按项数)", "")
    info("1x 下一条按'总字数'判, 不按项数 (说明行, 非判据; 不计入 PASS/FAIL)")
    # ⚠️⚠️ **项数 ≠ 字数**: `snap_dout` 一项就是 36 个字 (FE14+DP22 两束); 而
    #    `p7bdp_dout[k*32 +: 32]` 这类**切片**一项才是 1 个字。所以真正要核的是
    #    **总位数 == NW*32** (少一位 => 高位悬空 X; 多一位 => 被截断) —— 这也是
    #    wrapper 里那条注释的**正确形式** (旧文字写"拼接项数必须恰好 SNAP_NW_P6E",
    #    在"束作为一项"的装配里是**错的**, 本轮核对时当场撞上: 22 项 / 57 字)。
    def words_of(item, src):
        if "+:" in item:                       # 切片 => 1 字 (位宽必须写 32)
            assert "*32 +: 32" in item, item
            return 1
        mm = re.search(r"wire\s*\[([^\]]+)\]\s*%s\s*;" % re.escape(item), src)
        if mm is None:
            return None
        expr = mm.group(1).replace(" ", "")
        for nm, val in (("SNAP_FE_NW", fe), ("SNAP_DP_NW", dp), ("SNAP_P7BFE_NW", pfe),
                        ("SNAP_P7BDP_NW", pdp), ("SNAP_TX_NW", tx), ("SNAP_NW_P6E", NW)):
            expr = expr.replace(nm, str(val))
        expr = re.sub(r"-1:0$", "", expr)
        try:
            bits = eval(expr, {"__builtins__": {}}, {})
        except Exception:
            return None
        return bits // 32 if bits % 32 == 0 else None

    tot = 0
    badw = []
    for it in items:
        w = words_of(it, src0)
        if w is None:
            badw.append(it)
        else:
            tot += w
    ck(len(badw) == 0, "1a 每项的字数可解析", "(不可解析: %s)" % (badw or "无"))
    ck(tot == NW, "1 **总字数 == SNAP_NW_P6E**",
       "(项数=%d, 逐项字数之和=%d, NW=%d)" % (len(items), tot, NW))

    # ---------- 判据 2: 最右一项 = snap_dout ----------
    ck(code_of(items[-1]) == "snap_dout", "2a 最右一项是 snap_dout", "(实际 '%s')" % code_of(items[-1])[:40])
    ck(words_of(code_of(items[-1]), src0) == 36, "2b snap_dout 一项占 36 字 (FE14+DP22)")

    # ---------- 判据 3: 束宽等式 (fe/dp/pfe/pdp/tx 已在上面取过) ----------
    ck(None not in (fe, dp, pfe, pdp, tx), "3a 五个束宽 localparam 都在",
       "(fe=%s dp=%s p7bfe=%s p7bdp=%s tx=%s)" % (fe, dp, pfe, pdp, tx))
    ck(fe + dp == 36, "3b FE+DP = 36 (snap_seq 的两束)", "(%d+%d)" % (fe, dp))
    # p7bdp 的槽 2..5 是占位 (由 tx 束搬运) => 有效字数 = pdp - 4
    ck(fe + dp + pfe + (pdp - 4) + tx == NW, "3 束宽等式 == NW",
       "(%d+%d+%d+(%d-4)+%d = %d)" % (fe, dp, pfe, pdp, tx, fe + dp + pfe + pdp - 4 + tx))

    # ---------- 判据 4: 旧字未移位 (与 git HEAD 逐项比对) ----------
    try:
        head = subprocess.check_output(["git", "-C", repo, "show", "HEAD:board/wrapper_p4.v"])
        hbody, _ = grab_concat(head.decode("utf-8"), r"wire\s*\[SNAP_NW_P6E\*32-1:0\]\s*snap_dout_all\s*=")
        hitems = [code_of(x) for x in split_top_items(hbody)]
        nitems = [code_of(x) for x in items]
        tail = nitems[len(nitems) - len(hitems):]
        ck(tail == hitems, "4 * 旧字未移位 (HEAD 的项 == 新表的尾部)",
           "(HEAD %d 项, 新表 %d 项 => 新增 %d 项全在 MSB 端)" % (len(hitems), len(nitems), len(nitems) - len(hitems)))
        if tail != hitems:
            for i, (x, y) in enumerate(zip(tail, hitems)):
                if x != y:
                    print("       第一处不同: 新表 '%s' vs HEAD '%s'" % (x[:50], y[:50]))
                    break
    except Exception as e:
        ck(False, "4 旧字未移位 (git HEAD 比对)", "(%s)" % e)

    # ---------- 判据 5: 新增项的槽号 <-> 字号 ----------
    #   ⚠️ 拼接是 **MSB 端先写** ⇒ 表里**最上面那一项 = 最高字号** (下标最大)。
    #      第一版把期望写成升序 (W51..W56) ⇒ 当场 FAIL (本门自己抓的第三处"我写错了期望")。
    #      这条次序正是 wrapper 注释反复警告的"手抄下标最容易错"的地方。
    #   ⚠️ 2026-10-10 (P7B-A7 构建 D): 新增的 **W65 不在 p7bdp 束里** —— 它在 **tx 束**
    #      (槽 4 = `txsnap_dout[4*32 +: 32]`), 因为它的源 (`mac_tx_10g.stat_tx_idle`) 在
    #      `tx_mii_clk` 域 ⇒ 不能进 dp 束。所以判据 5 拆成 5a (顶部 = tx 束槽) /
    #      5b (紧随其后 = p7bdp 的 W(NW-2)..W51) / 5c (逐槽 p7bdp 映射) / 5d (W65 跨文件)。
    #   ⭐ 2026-10-10 (构建 E): 顶端次序再变一次 —— 新字 W(NW-1) 这次**在 p7bdp 束里**
    #      (它的源 `tcp_tx_frame.stat_winstall` 在 dp 域), 所以顶端两项 = p7bdp 的 W(NW-1)
    #      与 tx 束的 W65; 紧随其后才是历史那 14 项 (W64..W51)。
    #      ⚠️ "最上面 = tx 束槽" 这条**只对 P7B-A7 那一代成立**, 不是不变量 (就地订正)。
    nnew_top = 4                              # 构建 F: W69/W68/W67/W66 (p7bdp 槽 29/28/27/26)
    ntx = 1                                   # 其后的 tx 束项数 (W65) —— 现在排第 5 项
    nnew = 14                                 # W64..W51 (槽 25..12) —— 历史段
    # ⭐ 2026-10-10 (构建 F): 顶端再变一次 —— 三个新字**全在 p7bdp 束里** (槽 27/28/29),
    #   加上 E 代的 W66 (槽 26) ⇒ 顶端**四项** = p7bdp 的 W69/W68/W67/W66, 第五项才是
    #   tx 束的 W65, 紧随其后才是历史那 14 项 (W64..W51)。
    #   ⚠️ "最上面 = 哪一束" **不是不变量** (E 代是 p7bdp 打头、D 代是 tx 束打头)
    #   —— 每代都要按该代的接线逐项核 (本条第一版就把 nnew_top 写成 3 ⇒ 当场 FAIL)。
    topn = [code_of(x) for x in items[0:nnew_top]]
    want_top = ["p7bdp_dout[%d*32 +: 32]" % (pdp - 1 - i) for i in range(nnew_top)]
    ck(topn == want_top,
       "5a 最上面 %d 项 = W%d/W%d/W%d/W%d (p7bdp 束槽 %d/%d/%d/%d; 构建 F)"
       % (nnew_top, NW - 1, NW - 2, NW - 3, NW - 4, pdp - 1, pdp - 2, pdp - 3, pdp - 4),
       "(实际 %s, 期望 %s)" % (topn, want_top))
    top2 = code_of(items[nnew_top])
    want2 = "txsnap_dout[%d*32 +: 32]" % (tx - 1)
    ck(top2 == want2, "5a' 第 %d 项 = W65 (tx 束槽 %d; P7B-A7)" % (nnew_top + 1, tx - 1),
       "(实际 '%s', 期望 '%s')" % (top2, want2))
    topN = [code_of(x) for x in items[nnew_top + ntx:nnew_top + ntx + nnew]]
    #   槽号 = 字号 − 39 (W51→12 … W64→25); ⚠️ 第一版把 `64-i` 当槽号写 ⇒ 当场 FAIL
    #   (本门自己抓的又一处"手抄下标"错 —— 与它注释里警告的是同一类)。
    wantN = ["p7bdp_dout[%d*32 +: 32]" % (25 - i) for i in range(nnew)]   # W64..W51 (槽 25..12)
    ck(topN == wantN, "5b 紧随其后 %d 项 = W64..W51 的槽 (MSB 先写; p7bdp)" % nnew,
       "(实际 %s)" % topN)
    #   槽号映射 (⚠️ **分段**: W51..W64 = 槽 12..25 (字号−39), 而 W66..W69 = 槽 26..29
    #   (字号−40) —— 因为 **W65 落在 tx 束**, 把 p7bdp 的槽号序列打出一个洞)。
    slot_map = [(k, k - 39) for k in range(51, 65)] + [(k, k - 40) for k in range(66, NW)]
    for k, slot in slot_map:
        pat = r"assign\s+p7bdp_din\[%d\*32\s*\+\:\s*32\]\s*=\s*biz_w%d\s*;" % (slot, k)
        ck(re.search(pat, src0) is not None, "5c 槽号映射 W%d" % k,
           "(p7bdp_din[%d*32 +: 32] = biz_w%d)" % (slot, k))
    # 5d: W65 的**跨文件一致性** (端口 ↔ 接线 ↔ 束槽). 防两种半成品:
    #     "端口加了但没接快照字" (被综合整条优化掉) 与 "只在 wrapper 接、`mac_tx_10g`
    #     没那个端口" (只有合体构建才报错); 另防"接进了错的槽" (最高槽必须是它)。
    mt = os.path.join(repo, "_proj_10g", "p7b_mac", "rtl", "mac_tx_10g.v")
    mts = read(mt) if os.path.exists(mt) else ""
    ck(re.search(r"output\s+reg\s+\[31:0\]\s+stat_tx_idle", mts) is not None,
       "5d mac_tx_10g 有 `output reg [31:0] stat_tx_idle` 端口")
    ck(re.search(r"\.stat_tx_idle\s*\(\s*mtx_stat_tx_idle\s*\)", src0) is not None,
       "5d wrapper 把它接到 `mtx_stat_tx_idle` (mac_tx_10g 例化点)")
    ck(re.search(r"wire\s+\[31:0\]\s+mtx_stat_tx_idle", src0) is not None,
       "5d `mtx_stat_tx_idle` 已声明 (防隐式 1 位网)")
    m5 = re.search(r"txsnap_din\s*=\s*\{", src0)
    seg5 = src0[m5.end():m5.end() + 200] if m5 else ""
    f5 = re.search(r"[A-Za-z_]\w*", seg5)
    ck(m5 is not None and f5 is not None and f5.group(0) == "mtx_stat_tx_idle",
       "5d `txsnap_din` 的第一个拼接项 = `mtx_stat_tx_idle` (槽 4 → W65, tx 束最高槽)",
       "(实际 '%s')" % (f5.group(0) if f5 else None))

    # ---------- 判据 12 (构建 E + F): W66/W67/W69 (tcp_tx_frame) + W68 (tcp_rx) 跨文件一致性 ----------
    #   与判据 9/10/11 同款, 防三种半成品: ①端口加了但没接快照字 (被综合整条优化掉);
    #   ②只在 wrapper 接、源模块没那个端口 (只有合体构建才报错); ③接进了错的槽。
    #   另加一条**双分支**断言: 计数器在 `tcp_rx`/`tcp_tx_frame` 的每个 `ifdef` 分支里都必须
    #   **被驱动** —— 只在 OVL 分支写 ⇒ 默认构建里那是**未赋值的 reg** (仿真 X / 综合警告),
    #   而 xvlog 对"reg 没被赋值"一个字都不打印 (哑门族) ⇒ 必须静态数 (下面 n_inc)。
    ttf = read(os.path.join(repo, "rtl", "tcp_tx_frame.v"))
    rrx = read(os.path.join(repo, "rtl", "tcp_rx.v"))
    w12 = [
        # (文件标签, 源文本, 端口, wrapper 线名, 字号, 槽号, 驱动式, 期望驱动次数)
        ("tcp_tx_frame", ttf, "stat_winstall", "tx_stat_winstall", 66, pdp - 4,
         r"if \(stat_winstall_ev\) stat_winstall <= stat_winstall \+ 32'd1;", 2),
        ("tcp_tx_frame", ttf, "stat_winstall_cap", "tx_stat_winstall_cap", 67, pdp - 3,
         r"if \(stat_winstall_cap_ev\) stat_winstall_cap <= stat_winstall_cap \+ 32'd1;", 2),
        ("tcp_rx", rrx, "stat_ack_adv", "rx_stat_ack_adv", 68, pdp - 2,
         r"if \(ack_adv_ev\) stat_ack_adv <= stat_ack_adv \+ 32'd1;", 1),
        ("tcp_tx_frame", ttf, "o_win_at_winstall", "tx_win_at_winstall", 69, pdp - 1,
         r"if \(stat_winstall_ev\) o_win_at_winstall <= \{win_inflight, win_wnd_eff\};", 2),
    ]
    for flabel, fsrc, port, wire, word, slot, drv, n_inc in w12:
        ck(re.search(r"output\s+reg\s+\[31:0\]\s+%s" % re.escape(port), fsrc) is not None,
           "12 %s 有 `output reg [31:0] %s` 端口" % (flabel, port))
        got = len(re.findall(drv, fsrc))
        ck(got == n_inc,
           "12 `%s` 的驱动块在每个 ifdef 分支里都有 (= %d 次)" % (port, n_inc),
           "(实测 %d 次)" % got)
        ck(re.search(r"\.%s\s*\(\s*%s\s*\)" % (re.escape(port), re.escape(wire)), src0) is not None,
           "12 wrapper 把 `%s` 接到 `%s`" % (port, wire))
        ck(re.search(r"wire\s+\[31:0\]\s+%s" % re.escape(wire), src0) is not None,
           "12 `%s` 已声明 (防隐式 1 位网)" % wire)
        ck(re.search(r"biz_w%d\s*=\s*%s" % (word, re.escape(wire)), src0) is not None,
           "12 `biz_w%d` (= W%d) 由 `%s` 驱动" % (word, word, wire))
        ck(re.search(r"p7bdp_din\[%d\*32\s*\+\:\s*32\]\s*=\s*biz_w%d\s*;" % (slot, word), src0) is not None,
           "12 `p7bdp_din[%d*32 +: 32] = biz_w%d` (槽 ↔ 字)" % (slot, word))


    # ---------- 判据 6: p7bdp_din 驱动项数 ----------
    gen = re.search(r"for\s*\(\s*gi\s*=\s*0\s*;\s*gi\s*<\s*(\d+)\s*;", src0)
    ck(gen is not None, "6a p7bdp generate 存在")
    gen_n = int(gen.group(1))
    nassign = len(re.findall(r"assign\s+p7bdp_din\[(\d+)\*32\s*\+\:\s*32\]\s*=", src0))
    ck(gen_n + nassign == pdp, "6 p7bdp_din 驱动项数 == SNAP_P7BDP_NW",
       "(generate %d + 显式 %d = %d, NW=%d)" % (gen_n, nassign, gen_n + nassign, pdp))

    # ---------- 判据 7: 装配里的每个标识符都已声明且声明在使用之前 ----------
    #   ⚠️ 为什么这一条不能靠 xvlog: 未声明的名字会被当**合法隐式 1 位网**
    #      (实测: 在拼接里写 typo 名, xvlog rc=0 且日志全空) => 只有静态扫描能守。
    src = src0
    names = []
    for it in split_top_items(body):
        for tok in re.findall(r"\b([A-Za-z_]\w*)\b", it):
            if re.match(r"^[0-9]", tok) or tok in ("d", "b", "h", "o", "x", "z"):
                continue
            if tok not in names:
                names.append(tok)
    undeclared = []
    for nm in names:
        decl = re.search(r"(?:wire|reg|input|output|inout|localparam|parameter)\b[^;\n]*\b%s\b" % re.escape(nm), src)
        if decl is None:
            undeclared.append(nm)
            continue
        first_use = None
        for mm in re.finditer(r"\b%s\b" % re.escape(nm), src):
            if mm.start() >= decl.end():
                first_use = mm.start()
                break
        if first_use is None:
            undeclared.append(nm + "(只有声明,无使用?)")
    ck(len(undeclared) == 0, "7 * 装配里的标识符全部'先声明后用'",
       "(扫描 %d 个名字: %s; 未声明/晚声明: %s)" % (len(names), ",".join(names), ",".join(undeclared) or "无"))

    # ---------- 判据 8: 译码位宽 vs 回绕红线 ----------
    asrc = read(apath)
    m8 = re.search(r"wire\s*\[(\d+):0\]\s*ar_word\s*=\s*s_axil_araddr\[(\d+):2\]", asrc)
    ck(m8 is not None, "8a ar_word 声明可解析")
    width = int(m8.group(2)) - 1 if m8 else 0
    unimpl_word = (0x20 + 4 * NW) >> 2
    ck(unimpl_word < (1 << width), "8 * 未实现地址不回绕",
       "(addr=0x%X => word %d < 2^%d=%d)" % (0x20 + 4 * NW, unimpl_word, width, 1 << width))
    m9 = re.search(r"wire\s*\[(\d+):0\]\s*snap_base\s*=\s*\{snap_idx,\s*5'b0\}", asrc)
    ck(m9 is not None, "8b snap_base 声明可解析")
    w2 = int(m9.group(1)) + 1 if m9 else 0
    need = (NW - 1) << 5
    ck(need < (1 << w2), "8c snap_base 装得下 (NW-1)<<5", "(need=%d < 2^%d=%d)" % (need, w2, 1 << w2))
    m10 = re.search(r"SNAP_W0_IDX\s*=\s*(\d+)", asrc)
    ck(m10 is not None and int(m10.group(1)) == 8, "8d SNAP_W0_IDX == 8 (窗口起点 0x20)")

    # ---------- 判据 9: 跨文件一致性 (W56 的端口 ↔ 快照字) ----------
    #   ⚠️ 这一条防的是"只加端口不接快照字 ⇒ 被综合整条优化掉"与"只在 wrapper 接、
    #      `app_udp_pattern` 没有那个端口 ⇒ 合体构建的 xelab 才报错"两种半成品状态。
    #      xvlog 只编 wrapper_p4.v 时**看不到** app_udp_pattern 的端口表 ⇒ 必须有这一条。
    ap = os.path.join(repo, "rtl", "app_udp_pattern.v")
    asrc2 = read(ap) if os.path.exists(ap) else ""
    ck(re.search(r"output\s+reg\s+\[31:0\]\s+stat_tx_ovf", asrc2) is not None,
       "9a app_udp_pattern 有 `output reg [31:0] stat_tx_ovf` 端口")
    ck(re.search(r"\.stat_tx_ovf\s*\(\s*udpapp_tx_ovf\s*\)", src0) is not None,
       "9b wrapper 把它接到 `udpapp_tx_ovf`")
    ck(re.search(r"wire\s+\[31:0\]\s+udpapp_tx_ovf", src0) is not None,
       "9c `udpapp_tx_ovf` 已声明 (防隐式 1 位网)")
    ck(re.search(r"biz_w56\s*=\s*udpapp_tx_ovf", src0) is not None,
       "9d `biz_w56` (= W56) 由 `udpapp_tx_ovf` 驱动")

    # ---------- 判据 10: 追加 C 的**接线方向** (最易犯的错 = 两个适配器接反) ----------
    #   两条慢路径适配器的 `stat_fifo_ovf` 是**同名端口** ⇒ 接反了 xvlog/xelab 都不会报
    #   (类型相同、都存在), 只有"哪根线接哪个模块"这一条能判。
    for mod, wire, word in (("slow_tx_adp", "stx_stat_fifo_ovf", 59),
                            ("slow_rx_adp", "srx_stat_fifo_ovf", 60)):
        ap2 = os.path.join(repo, "rtl", mod + ".v")
        a2 = read(ap2) if os.path.exists(ap2) else ""
        ck(re.search(r"output\s+reg\s+\[31:0\]\s+stat_fifo_ovf", a2) is not None,
           "10 %s 有 `output reg [31:0] stat_fifo_ovf`" % mod)
        # 该模块的例化块内必须连到**同名线** (用模块名到下一个 `);` 之间的片段判)
        mm = re.search(r"%s\s+u_\w+\s*\((.*?)\n\s*\);" % mod, src0, re.S)
        ck(mm is not None and re.search(r"\.stat_fifo_ovf\s*\(\s*%s\s*\)" % wire, mm.group(1)) is not None,
           "10 %s.stat_fifo_ovf 接到 `%s` (不是接反)" % (mod, wire))
        ck(re.search(r"biz_w%d\s*=\s*%s" % (word, wire), src0) is not None,
           "10 `biz_w%d` (= W%d) 由 `%s` 驱动" % (word, word, wire))

    # ---------- 判据 11 (2026-10-10, P7B-GAP9-TX): W63/W64 的**跨文件一致性** ----------
    #   与判据 9/10 同款: 防 "端口加了但没接快照字" / "只在 wrapper 接, app_pattern 没那个端口"
    #   这两种半成品状态 (xvlog 只看 wrapper 时看不见 app_pattern 的端口表)。
    for mod, port, wire, word in (("app_pattern", "stat_frmwait_cyc", "app_frmwait_cyc", 63),
                                  ("app_pattern", "stat_bp_cyc", "app_bp_cyc", 64)):
        ap3 = os.path.join(repo, "rtl", mod + ".v")
        a3 = read(ap3) if os.path.exists(ap3) else ""
        ck(re.search(r"output\s+reg\s+\[31:0\]\s+%s" % re.escape(port), a3) is not None,
           "11 %s 有 `output reg [31:0] %s` 端口" % (mod, port))
        ck(re.search(r"\.%s\s*\(\s*%s\s*\)" % (re.escape(port), re.escape(wire)), src0) is not None,
           "11 wrapper 把 %s 接到 `%s` (app_pattern 例化点)" % (port, wire))
        ck(re.search(r"wire\s+\[31:0\]\s+%s" % re.escape(wire), src0) is not None,
           "11 `%s` 已声明 (防隐式 1 位网)" % wire)
        ck(re.search(r"biz_w%d\s*=\s*%s" % (word, re.escape(wire)), src0) is not None,
           "11 `biz_w%d` (= W%d) 由 `%s` 驱动" % (word, word, wire))

    print("----------------------------------------------------------")
    # ⚠️ INFO 单列: 恒真说明行**不进 PASS 计数** (原 `ck(True, ...)` 那行曾虚增 PASS 1 个)
    print("PASS=%d FAIL=%d INFO=%d" % (len(PASSES), len(FAILS), len(INFO)))
    if FAILS:
        print("FAILED: " + ", ".join(FAILS))
        return 1
    print("CHECK_WINDOW_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
