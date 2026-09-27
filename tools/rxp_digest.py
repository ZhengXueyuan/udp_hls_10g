#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""rxp_digest.py — 把一条或多条 RXP 状态行读成 §16.10 的位移律摘要。

它把"这一轮是否还是同一个现象"变成一组**可重跑**的检查 (ISSUE §16.10 的四条规律):
  1. II % paylen == 0        首失配落在帧边界 (整帧替换的必然结果)
  2. k == +paylen            收到的整字 == 流里"下一帧同偏移"的字, 且**在宽窗口内唯一**
  3. UMM / (paylen*255/256)  是整数 —— 受损帧数
  4. OZ == 该整数            字节级分桶与帧级计数互证
  5. 每帧桶剖面 == 容量*255/256  (整帧逐字节均匀替换)

**为什么要"宽窗口 + 整字 8 字节精确匹配"**: 只在正方向搜 `k` 永远搜不到 `-paylen`,
那样"找到 +paylen"就只是"在预设方向上找到的第一个解", 不能支撑单向性结论。
本工具在 +-W 内做**全搜**, 命中多于一个就报出来 (多命中 ⇒ 该轮的出处不可判)。

paylen 由 URB/URF 反推: 在候选表里找满足 `ceil(URB/pl) == URF` 的 pl。
⚠️ **不要用 URB/URF 当 paylen** —— 8388608/5699 = 1471.944 是浮点 (末尾有不满帧),
拿它去取模会得到一堆假余数 (2026-09-27 我自己这么错过一次)。

用法:
  python tools/rxp_digest.py p5diag_verify/v3_round*.line
  python tools/rxp_digest.py --window 200000 p5diag_verify/v3_long*.line
"""
import math
import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0].rsplit("\\", 1)[0] + "/tools")
try:
    import rxp_classify as R
except ImportError:                                    # 直接在本目录跑时的兜底
    sys.path.insert(0, ".")
    import rxp_classify as R

PAYLEN_CAND = [512, 996, 1024, 1280, 1400, 1408, 1460, 1472, 1500]
PAYLEN_DEFAULT = 1472          # 仅用于**估尺寸**(图案要多大), 不是判据


def infer_paylen(urb, urf):
    """候选中满足 ceil(URB/pl) == URF 的 paylen (可能多解, 全部返回)。"""
    return [pl for pl in PAYLEN_CAND if urf and math.ceil(urb / pl) == urf]


# ---------------------------------------------------------------- v4 (帧序号轨迹)
# 字段语义 (权威 = rtl/app_status_uart.v 与 rtl/udp_split.v 的注释):
#   A 部 (udp_split, 异常帧路径; 每拍脉冲计数, 本轮累计):
#     CN 描述符满⇒回卷次数 · RD 残帧边界回卷次数 · NC/NP 0长数据报事件/提交
#     WF uf_ovf 拍数(字数口径) · RL 回卷拍数 · WC 字数一致性违例
#   B 部 (app_udp_pattern):
#     NE 偏移0失配事件数(≡OZ) · NR 极大连续段数 · MR 最长段长
#     EN 已入队条目数 · EO 有事件未记录(粘滞) · QA..QH 每条 24b = {帧号[15:0], rx_got[7:0]}
A_KEYS = ("CN", "RD", "NC", "NP", "WF", "RL", "WC")
# ⚠️ WF / RL 是**拍/字**口径, 与"整帧数 n"**量纲不同** ⇒ 不能拿"== n"当根因判据
# (审查 C5 抓到: 我原先给任何等于 n 的计数器都打"★根因候选", 对 WF/RL 是错的)。
WORD_DIM = ("WF", "RL")
B_KEYS = ("NE", "NR", "MR", "EN", "EO")
Q_KEYS = ["Q" + c for c in "ABCDEFGH"]
# v5 (2026-09-27, ISSUE_RX_BYTE_CORRUPTION section 14.6/18.8):
#   A part = the SECOND LFSR byte checker, sitting on the u_uf WRITE data port (u_m_d)
#   B part = udp_rx's parser counters, previously dangling inside udp_split
# 键名: DV DG DE DO DM VZ (A) 与 PS NM IC DC SB (B); 偏移/语义见 rtl/app_status_uart.v
# 的 v5 段注释 (真值源) 与 rtl/udp_split.v 的 v5 段。
V5_A_KEYS = ("DV", "DG", "DE", "DO", "DM", "VZ")
V5_B_KEYS = ("PS", "NM", "IC", "DC", "SB")
# v6 (2026-09-27, ISSUE_RX_BYTE_CORRUPTION section 18.9/18.10):
#   the THIRD LFSR byte checker, sitting on udp_split's INPUT PORT SIDE (s_axis, the
#   stream entering u_pre).  This is the adjudication point of the section-18.9
#   contradiction: it is the only stream on the path that was never instrumented.
# 键名 CV CG CE CO CM CZ + CS (CS = input-skid dropped words; non-zero => the v6
#   reading is unusable for that round).  Offsets/semantics: rtl/app_status_uart.v
#   and rtl/udp_split.v, the v6 blocks (the truth sources).
V6_KEYS = ("CV", "CG", "CE", "CO", "CM", "CZ")
V6_SKIP_KEY = "CS"


def v4_section(d, pat, paylen, n_int):
    """打印 v4 专有判读。返回若干 (标题, 结论) 供 main 汇总。"""
    has_a = any(k in d for k in A_KEYS)
    has_b = any(k in d for k in B_KEYS)
    if not (has_a or has_b):
        return []
    g = lambda k: int(d[k], 16) if k in d else None
    out = []
    print("   ---- v4: A 部 异常帧路径计数器 (本轮累计) ----")
    if has_a:
        # 判据: 哪个计数器 == 本轮受损帧数 n ⇒ 它就是根因
        for k in A_KEYS:
            v = g(k)
            if v is None:
                continue
            tag = ""
            if n_int is not None and v == round(n_int) and v != 0:
                if k in WORD_DIM:
                    tag = "   <== ⚠️ 数值等于 n 但**量纲不同**(%s 是字/拍, n 是帧) ⇒ **不可**当根因判据" % k
                else:
                    tag = "   <== ★ 恰等于整帧数 n, 它就是根因候选"
            print("      %-3s = %-8d%s" % (k, v, tag))
        if n_int is not None:
            print("      (对照: 本轮整帧数 n = %.2f;  %s 是字/拍口径, 与 n 不可比)"
                  % (n_int, "/".join(WORD_DIM)))
        nz = [k for k in A_KEYS if g(k)]
        if not nz:
            print("      ⇒ A 部全 0: 三处异常帧路径**本轮都没触发** ⇒ 归属不在这几条通路")
        else:
            print("      ⇒ 非 0 的路径: %s" % ", ".join(nz))
    print("   ---- v4: B 部 运行结构 ----")
    ne, nr, mr = g("NE"), g("NR"), g("MR")
    if None not in (ne, nr, mr):
        print("      NE=%d  NR=%d  MR=%d" % (ne, nr, mr))
        if ne == nr:
            print("      ⇒ NR == NE ⇒ **受损帧全部孤立** (每个事件不相邻)")
        else:
            print("      ⇒ NR < NE ⇒ **存在连续段** (极大段数 %d, 最长 %d) "
                  "⇒ 帧边界整体位移的签名" % (nr, mr))
        oz = g("OZ")
        if oz is not None and oz != ne:
            print("      ⚠️ NE=%d != OZ=%d —— NE 与 OZ 由同一表达式驱动, 不等说明仪器有问题" % (ne, oz))
        if any(g(k) for k in ("CN", "RD", "WF", "RL")):
            print("      ⚠️ **CN/RD/WF/RL 非 0 ⇒ 本轮有回卷/丢字, NR/MR 必须作废重判** "
                  "(丢帧后 app 的 LFSR 断流, 此后每帧首字节都失配)")
    en, eo = g("EN"), g("EO")
    if en is not None:
        print("      事件 FIFO: EN=%d 条已记  EO=%d (1 = 有事件未记录, 粘滞)" % (en, eo or 0))
    # ---- 逐条事件: 位移符号 + 环相位 ----
    ents = [(i, g(k)) for i, k in enumerate(Q_KEYS) if g(k)]
    if ents:
        # 保护: 条目里的帧号可能超出已生成图案 ⇒ 那会静默显示"无匹配", 看起来像"位移不是 ±1 帧"。
        far = [f for _, v in ents for f in (v >> 8,) if (f + 1) * paylen >= len(pat)]
        if far:
            print("      ⚠️ 条目的帧号 %s 超出已生成图案 (%d 字节, 覆盖到帧 %d) ⇒ "
                  "下面的『无匹配』是**图案不够长**, 不是位移结论; 加大 --window。"
                  % (sorted(set(far)), len(pat), len(pat) // paylen - 1))
    if ents:
        wpf = -(-paylen // 8)          # 每帧字数 ceil(paylen/8)
        print("   ---- v4: 事件条目 (前 8 条) 位移符号 + 环相位 ----")
        print("      %-4s %-7s %-5s %-34s %s" % ("条目", "帧号", "got", "定点判定 (d=0, c = 帧偏移)", "环相位 (帧号×%d) mod 512" % wpf))
        for i, v in ents:
            f, got = v >> 8, v & 0xFF
            # 主判据: d == 0 —— 整帧替换应**恰好**落在某个帧边界上, 不带字节偏移。
            # 次判据: 小窗口内的非零字节偏移 (可能是巧合: 3 候选 x 16 偏移 ≈ 51/256 ≈ 20%).
            # ⚠️ 候选 c 必须**覆盖到整串长度**: 板级实测受损帧是"窗口内 L 帧载荷循环右移一位"
            # (见 §18), 所以串内第 i 个成员的位移是 +(1) 而**最后一个**是 -(L-1)。
            # 原先只测 c∈{-1,0,+1} ⇒ 串尾成员一律显示"无匹配", 把旋转误读成"孤立"。
            CR = 8
            exact = [c for c in range(-CR, CR + 1)
                     if 0 <= (f + c) * paylen < len(pat) and pat[(f + c) * paylen] == got]
            near = [(c, dd) for c in (-1, 0, 1) for dd in list(range(-8, 0)) + list(range(1, 9))
                    if 0 <= (f + c) * paylen + dd < len(pat) and pat[(f + c) * paylen + dd] == got]
            NM = {0: "本帧(c=0, 即干净)", 1: "**下一帧(c=+1)**"}
            def nm(c):
                if c == 0:
                    return NM[0]
                if c == 1:
                    return NM[1]
                if c < 0:
                    return "★ **上一帧往回 %d 帧(c=%d), 即 L=%d 循环旋转的串尾**" % (-c, c, -c + 1)
                return "c=+%d(超前 %d 帧)" % (c, c)
            if len(exact) == 1:
                verdict = "★ " + nm(exact[0])
            elif len(exact) == 0:
                verdict = "无定点匹配 ⇒ 该条不可用(串长可能 > %d)" % CR
            else:
                verdict = "多候选同值(1/256 巧合) ⇒ 该条不可用: " + ", ".join(nm(c) for c in exact)
            print("      %-4d %-7d 0x%02X  %-34s %s" % (i, f, got, verdict, (f * wpf) % 512))
        if en is not None and en < len(ents):
            print("      (EN=%d 与已解码条目数 %d 不符 —— 检查 EN 口径)" % (en, len(ents)))
        print("      ※ 单条 got 与某候选相等有 1/256 的巧合概率; **结论看 8 条的一致性**, 不看单条")
    # 回传给 main 做**跨轮聚合**(§17.7 预注册判据要 50+ 样本, 单轮只有 ≤8 条)
    phases = [(paylen, (v >> 8) * wpf % 512) for _, v in ents] if ents else []
    return phases


def v5_section(d, paylen, ii, umm, urb, urf, rl, wf):
    """打印 v5 专有判读 (ISSUE_RX_BYTE_CORRUPTION section 14.6 / 18.8).

    A 部 = u_uf **写数据口** (u_m_d) 上的第二个 LFSR 逐字节校验器:
      DV 首个失配的累计字节序号 | DG/DE 该处 收/期望 字节 | DO 该处帧内偏移
      DM 失配字节总数 | VZ 快照有效 (粘滞)
      ⇒ 它与 v3 的 SW **机制不同** (SW 按 `w_commit_cnt[2:0]` 帧号定址, 本组纯字节计数)
        所以两条路径的读数可以互相裁决 (SW 的采集依赖一条无法从 TB 构造的结构假设)。
    B 部 = udp_rx 的解析器计数, 原来在 udp_split 内部悬空、从未显示:
      PS stat_pass | NM drop_nonmatch | IC drop_ipcsum | DC drop_crc | SB stat_bytes
      ⇒ **PS vs URF** 是 §16.7 要的那条判据 (不等 ⇒ 解析器与 app 之间有丢帧/重帧)。

    ⚠️ 口径 (读之前必看): 跨机制对照 `DV == II` / `DM == UMM` 要求 **RL == 0 且 WF == 0**
      (回卷/满吞会把写流与交付流的序号错开; 板级 8/8 轮满足, 见 §18.2/§18.5)。
      内容口径稍宽: 回卷**不**改写流内容, 只有 WF 会挖洞。
    """
    if not any(k in d for k in V5_A_KEYS + V5_B_KEYS):
        return []
    g = lambda k: int(d[k], 16) if k in d else None
    print("   ---- v5: A 部 写数据口 (din) 的第二个 LFSR 校验器 ----")
    if any(k in d for k in V5_A_KEYS):
        dv, dg, de = g("DV"), g("DG"), g("DE")
        do, dm, vz = g("DO"), g("DM"), g("VZ")
        print("      DV=%-10s DG=%s DE=%s DO=%-6s DM=%-10s VZ=%s"
              % (dv, ("%02X" % dg) if dg is not None else "-",
                 ("%02X" % de) if de is not None else "-", do, dm, vz))
        gate = (rl == 0 and wf == 0)
        print("      前置闸 (跨机制对照): RL=%s WF=%s ⇒ %s"
              % (rl, wf, "可用 (DV==II / DM==UMM 可判)" if gate else
                 "**不可用** (回卷/满吞已把两条流的序号错开; 只有内容口径仍成立)"))
        if vz == 0:
            print("      VZ=0 ⇒ 本轮 din 上没有出现任何失配 (干净流)")
        else:
            if paylen and dv is not None and do is not None:
                ok = (do == dv % paylen)
                print("      锚关系 DO == DV %% paylen = %s  %s"
                      % (dv % paylen, "✓" if ok else "✗ (锚口径坏了, 先修仪器再读)"))
            if ii is not None and dv is not None:
                print("      DV=%-8d vs app 的 II=%-8d %s" % (dv, ii, "✓ 相同" if dv == ii
                      else "✗ 不同 (两个机制的锚不一致 ⇒ SW 的归因假设被这条独立路径否证)"))
            if umm is not None and dm is not None:
                print("      DM=%-8d vs app 的 UMM=%-8d %s" % (dm, umm, "✓ 相同" if dm == umm
                      else "✗ 不同"))
            print("      ※ DO == 0 且 DM ≈ UMM 的整帧数 ⇒ 与 §18 的『窗口内循环旋转』同形")
            print("        (旋转的首个坏字节必然落在帧内偏移 0 ⇒ DO=0)")
    if any(k in d for k in V5_B_KEYS):
        ps, nm, ic, dc, sb = (g("PS"), g("NM"), g("IC"), g("DC"), g("SB"))
        print("   ---- v5: B 部 解析器 (udp_rx) 计数 [§16.7 判据: PS vs URF] ----")
        print("      PS=%-10s NM=%-10s IC=%-10s DC=%-10s SB=%-10s"
              % (ps, nm, ic, dc, sb))
        if ps is not None and urf is not None:
            print("      PS=%-8d vs app 的 URF(交付帧数)=%-8d %s"
                  % (ps, urf, "✓ 相同 ⇒ 解析器与 app 之间无丢帧/重帧" if ps == urf else
                     "✗ **不等 ⇒ 解析器与 app 之间有丢帧/重帧 (重大线索)**"))
        if sb is not None and urb is not None:
            print("      SB=%-8d vs app 的 URB(交付字节)=%-8d %s"
                  % (sb, urb, "✓ 相同" if sb == urb else "✗ 不同 (声明长度口径 vs 交付口径)"))
        tot = sum(x for x in (ps, nm, ic, dc) if x is not None)
        print("      (PS+NM+IC+DC = %s —— 四条路径互斥, 应等于解析器看到的帧总数)" % tot)
    return []


def v6_section(d, paylen, ii, umm, dv, dm, cs):
    """打印 v6 专有判读 (ISSUE_RX_BYTE_CORRUPTION section 18.9/18.10).

    位置 = **udp_split 的输入端口侧** (s_axis, 进 u_pre 之前) —— §18.9 那个
    "三者不能同时为真"矛盾的唯一裁决点 (u_pre 的输入是整条链上唯一没插桩的流)。

      裁决表 (与 v5 的 din 侧对照):
        v6 干净 (CZ=0) 且 v5 损坏  ⇒ 重排在 **u_pre 或 udp_rx 内部**
                                    (头号嫌疑: udp_split_fifo 的 LUTRAM 读语义/满空标志)
        v6 也损坏                  ⇒ 在 **mac_rx_64 / rx_classify / vlan_strip**
                                    ⇒ 必须带着这个反例重查"无帧级存储"的论证

    ⚠️ 口径: CV/CM 是**输入侧**的累计载荷字节 (所有到达 udp_split 的字, 含被判非匹配
      而丢弃的帧); v5 的 DV/DM 是**写口**的累计 (只有真正写进 u_uf 的)。两者只在
      "输入流 == 写入流"时逐字节可比 —— 满吞 (WF>0) 会让 v5 少算, 回卷 (RL>0) 不改写
      内容但会平移 app 侧序号。⇒ 跨机制对照 CV==DV / CM==DM 需要 WF==0;
      **与序号无关**的量 (CO / CG / CE) 不受影响, 可无条件对照。
    """
    if not any(k in d for k in V6_KEYS + (V6_SKIP_KEY,)):
        return
    g = lambda k: int(d[k], 16) if k in d else None
    print("   ---- v6: u_pre 输入侧 (s_axis) 的第三个 LFSR 校验器 ----")
    cv, cg, ce = g("CV"), g("CG"), g("CE")
    co, cm, cz = g("CO"), g("CM"), g("CZ")
    sk = g(V6_SKIP_KEY)
    print("      CV=%-10s CG=%s CE=%s CO=%-6s CM=%-10s CZ=%s CS=%s"
          % (cv, ("%02X" % cg) if cg is not None else "-",
             ("%02X" % ce) if ce is not None else "-", co, cm, cz, sk))
    if sk:
        print("      ⚠️ CS=%d != 0 ⇒ **本轮 v6 读数不可用**: 输入 skid 满而丢了 %d 个字"
              " (输入侧不能反压 ⇒ 只能丢)。板级 1G = 1 字/8 拍, 引擎 = 1 字/2 拍"
              " ⇒ 正常轮次 CS 恒 0。" % (sk, sk))
        return
    if cz == 0:
        print("      CZ=0 ⇒ 本轮**输入侧**没有任何失配 (u_pre 的输入是干净的)")
    else:
        if paylen and cv is not None and co is not None:
            ok = (co == cv % paylen)
            print("      锚关系 CO == CV %% paylen = %s  %s"
                  % (cv % paylen, "✓" if ok else "✗ (锚口径坏了, 先修仪器再读)"))
        if co is not None:
            print("      CO=%d ⇒ %s" % (co, "首个坏字节落在**帧内偏移 0** (与 §18 的"
                  "『窗口内循环旋转』同形)" if co == 0 else "首个坏字节不在帧首"))
    # ---- 裁决 (与 v5 的 din 侧对照) ----
    if dv is not None or dm is not None:
        print("      ---- §18.9 裁决 (v6 输入侧 vs v5 写口侧) ----")
        v5d = ("报出" if (dv or dm) else "干净")
        v6d = ("报出" if cz else "干净")
        print("      u_pre 输入侧 = %s ; din (写口) 侧 = %s" % (v6d, v5d))
        if cz == 0 and (dv or dm):
            print("      ⇒ ★ **重排发生在 u_pre 或 udp_rx 内部** (输入干净、写口已坏)")
            print("        头号嫌疑 = udp_split_fifo 的 LUTRAM 读语义 / 满空标志")
        elif cz and (dv or dm):
            print("      ⇒ ★ **输入侧也已损坏** ⇒ 在 mac_rx_64 / rx_classify / vlan_strip")
            print("        必须带着这个反例重查『din 之前无帧级存储』的论证")
        elif cz == 0 and not (dv or dm):
            print("      ⇒ 两侧都干净: 本轮没有受损样本 (或损坏在这两点的下游)")
        else:
            print("      ⇒ v6 报出而 v5 干净: 两条锚不一致 ⇒ 先查 CS/RL/WF 前置闸")
        if dv is not None and cv is not None:
            print("      序号对照 CV=%-8d v5 DV=%-8d %s" % (cv, dv,
                  "✓ 相同" if cv == dv else "✗ 不同 (满吞 WF/回卷会让两条序号错开)"))
        if dm is not None and cm is not None:
            print("      失配数   CM=%-8d v5 DM=%-8d %s" % (cm, dm,
                  "✓ 相同" if cm == dm else "✗ 不同"))
    return


def one(fn, W, pat, force_pl=None):
    line = open(fn, encoding="utf-8", errors="replace").read()
    line = re.search(r"^P5B1 .*$", line, re.M)
    if not line:
        return None, "no P5B1 line"
    line = line.group(0)
    d = dict(re.findall(r"([A-Z]{2})=([0-9A-Fx]+)", line))
    need = ("II", "MM", "OZ", "OL", "OM", "OH")
    if not all(k in d for k in need):
        return None, "missing fields (not a v2/v3 diag line?)"
    g = lambda k: int(d[k], 16)
    ii, umm = g("II"), g("MM")
    urb = int(re.search(r"URB=([0-9A-F]+)", line).group(1), 16) if "URB=" in line else None
    urf = int(re.search(r"URF=([0-9A-F]+)", line).group(1), 16) if "URF=" in line else None

    pls = infer_paylen(urb, urf) if (urb and urf) else []
    paylen = force_pl if force_pl else (pls[0] if len(pls) == 1 else None)
    amb = "" if paylen else "  paylen 反推%s" % ("歧义%s" % pls if pls else "失败")

    out = {"file": fn, "II": ii, "UMM": umm, "amb": amb, "paylen": paylen,
           "d": d, "OZ": g("OZ"), "OL": g("OL"), "OM": g("OM"), "OH": g("OH"),
           "urb": urb, "urf": urf, "rl": g("RL") if "RL" in d else None,
           "wf": g("WF") if "WF" in d else None}
    if paylen is None:
        return out, amb

    out["off"] = ii % paylen
    out["n"] = umm / (paylen * 255.0 / 256.0)
    out["nframes"] = math.ceil(urb / paylen) if urb else None

    # k: 整字 8 字节精确匹配, 全窗口搜索 (两侧都搜)
    if "GW" in d:
        G = int(d["GW"], 16)
        hits = [c for c in range(-W, W + 1)
                if 0 <= ii + c and ii + c + 8 <= len(pat)
                and int.from_bytes(bytes(pat[ii + c:ii + c + 8]), "big") == G]
        out["k_hits"] = hits
        out["k"] = hits[0] if len(hits) == 1 else None

    # 每帧桶剖面 vs 容量*255/256
    caps = [1, 7, 56, paylen - 64]
    out["prof"] = [out[b] / out["n"] for b in ("OZ", "OL", "OM", "OH")] if out["n"] else None
    out["caps"] = [c * 255.0 / 256.0 for c in caps]
    return out, amb


def main():
    a = sys.argv[1:]
    W = int(a[a.index("--window") + 1]) if "--window" in a else 200000
    force_pl = int(a[a.index("--paylen") + 1]) if "--paylen" in a else None
    files = [x for x in a if not x.startswith("--") and x != str(W) or x.endswith(".line")]
    files = [x for x in a if x.endswith(".line")]
    if not files:
        print(__doc__)
        return 1
    # 图案要同时覆盖两件事(审查 C8 抓到的真 bug —— 只按 II+W 定长会让条目大面积出废条):
    #   ① k 位移搜索需要 II ± W
    #   ② 事件条目的帧号 f 需要 (f+1)*paylen 可达 —— 首事件在帧 192 而后续条目在帧 5491 是常见的,
    #      所以尺寸必须按**整轮长度**定, 而不是按 II。
    maxii, need = 0, 0
    for fn in files:
        txt = open(fn, encoding="utf-8", errors="replace").read()
        m = re.search(r"\bII=([0-9A-F]+)", txt)
        if m:
            maxii = max(maxii, int(m.group(1), 16))
        rb = re.search(r"\bURB=([0-9A-F]+)", txt)
        if rb:
            need = max(need, int(rb.group(1), 16) + 2 * PAYLEN_DEFAULT)   # 整轮字节数 + 余量
        fr = 0
        for k in Q_KEYS:
            mm = re.search(r"\b%s=([0-9A-Fx]+)" % k, txt)
            if mm:
                try:
                    fr = max(fr, int(mm.group(1), 16) >> 8)
                except ValueError:
                    pass
        if fr:
            need = max(need, (fr + 2) * PAYLEN_DEFAULT + 16)
    size = max(maxii + W + 8, need)
    pat = R.pattern(size)
    print("图案流已生成 %d 字节 (max II %d + 窗口 %d; 条目帧号另需 %d)\n" % (len(pat), maxii, W, need))

    all_phases = []
    for fn in files:
        r, err = one(fn, W, pat, force_pl)
        if r is None:
            print("%-38s  ✗ %s" % (fn, err));  continue
        if r.get("paylen") is None:
            print("%-38s  ✗ %s" % (fn, r["amb"]));  continue
        k = r.get("k_hits")
        kstr = "唯一 +%d" % r["k"] if r.get("k") == r["paylen"] else \
               ("命中 %s" % k if k else "无命中")
        ok_k = "✓" if r.get("k") == r["paylen"] else "✗"
        ok_n = "✓" if abs(r["n"] - round(r["n"])) < 0.05 else "✗"
        ok_o = "✓" if r["OZ"] == round(r["n"]) else "✗"
        print("%s" % fn)
        print("   paylen=%-5d 帧数=%-6s II%%paylen=%-3d  UMM=%-8d 整帧数=%-7.2f %s"
              % (r["paylen"], r["nframes"], r["off"], r["UMM"], r["n"], ok_n))
        print("   k(唯一整字位移)=%-10s %s   OZ=%-4d == 整帧数? %s"
              % (kstr, ok_k, r["OZ"], ok_o))
        print("   每帧桶剖面 实测 %s" % ["%.1f" % v for v in r["prof"]])
        print("                    期望 %s   <- 容量x255/256" % ["%.1f" % v for v in r["caps"]])
        print("   受损帧占比 = %.5f%%  (n / 帧数)" % (100.0 * r["n"] / r["nframes"]))
        # 审查 C7: 帧号是 16 位且**静默**环绕。1472B 载荷下线速约 0.8 s 绕一圈。
        # 超过 65536 帧后 QA..QH 里的帧号回绕, 位移符号会在图案的**错误位置**找到唯一命中
        # (不是"无匹配") ⇒ 必须显式拦住, 否则会得到一个自信的错结论。
        if r.get("nframes") and r["nframes"] > 65536 and any(k in r["d"] for k in Q_KEYS):
            print("   ‼️ 本轮 %d 帧 > 65536 ⇒ **帧号已回绕**, 条目帧号与位移符号**不可用**"
                  " (除非把帧号加宽)。请把跑量限制在 < 65536 帧。" % r["nframes"])
        if r.get("d"):
            all_phases += v4_section(r["d"], pat, r["paylen"], r["n"])
        if r.get("d"):
            v5_section(r["d"], r["paylen"], r["II"], r["UMM"], r["urb"], r["urf"],
                       r["rl"], r["wf"])
        if r.get("d"):
            v6_section(r["d"], r["paylen"], r["II"], r["UMM"],
                       int(r["d"]["DV"], 16) if "DV" in r["d"] else None,
                       int(r["d"]["DM"], 16) if "DM" in r["d"] else None,
                       int(r["d"]["CS"], 16) if "CS" in r["d"] else None)
        print()

    # ---- 跨轮聚合: §17.7 预注册判据 (相位 0 是否超额) ----
    # 期望概率 p0 = gcd(每帧字数, 512) / 512 —— 随帧长变 (1472 -> 1/64, 512 -> 1/8),
    # 所以必须**按 paylen 分组**统计, 不能把两种帧长的条目混在一起。
    if all_phases:
        print("=" * 72)
        print("跨轮聚合 —— §17.7 预注册判据: 事件帧号的环相位 (帧号×每帧字数) mod 512")
        for pl in sorted(set(p for p, _ in all_phases)):
            ph = [x for p, x in all_phases if p == pl]
            wpf = -(-pl // 8)
            p0 = math.gcd(wpf, 512) / 512.0
            k0 = sum(1 for x in ph if x == 0)
            n = len(ph)
            # 单侧二项尾 P(X >= k0), X ~ Bin(n, p0)
            tail = sum(math.comb(n, i) * p0**i * (1 - p0)**(n - i) for i in range(k0, n + 1))
            print("  paylen=%-5d n=%-4d 相位0 出现 %-3d 次, 期望 %.2f (p0=1/%.0f)  P(X>=k0)=%.2e"
                  % (pl, n, k0, n * p0, 1 / p0, tail))
            if n < 50:
                print("     ⚠️ n=%d < 50 (预注册目标) ⇒ **样本不足, 不下结论**" % n)
            elif tail < 0.01:
                print("     ⇒ 相位 0 **显著超额** ⇒ 支持『帧号 ≡ 0 (mod 64) 且描述符落槽 0』类定址根因")
                print("       ⚠️ 但先查 CN/RD/WF/RL: 若它们非 0, 相位已被回卷整体平移, 该判据作废")
            else:
                print("     ⇒ 相位 0 未超额 ⇒ 预注册假设**否证**(环/槽定址类根因不成立)")
        print("=" * 72)


if __name__ == "__main__":
    sys.exit(main())
