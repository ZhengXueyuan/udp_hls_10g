#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""rxp_classify.py — RXP_DIAG 首失配快照的**离线判读器** (ISSUE_RX_BYTE_CORRUPTION)

背景: 诊断位流在 UART 状态行行尾给出 8 个字段 (键名 = "=" 前最后两个字母,
与 board_p5b_check.py 的 parse 口径一致):

  II = 失配字节的**全局收字节号** (= 图案流偏移, 因 RX LFSR 从 reset 起按 SEED 逐字节推进)
  GG = 收到的坏字节   EE = 期望字节   PP = 前一拍比对过的期望字节 (= 上一收到且匹配的字节)
  BA/BB/BC = 失配字节数 (popcount(GG^EE) 为 1 / 2 / >=3)
  DD = 失配且 "GG == 前一字节" 的次数 (重复/陈旧签名)
  GW/EW = 首失配所在的**整 64 位字** (收到 / 期望; 按**收到字的字边界**对齐, lane0=[63:56])
  OZ/OL/OM/OH = 帧内偏移分桶的失配计数 (0 / 1..7 / 8..63 / >=64)

**整字 GW 是本判读器最有力的一件**: 8 字节指纹在图案流里近似唯一 ⇒ 直接回答
"这份字是从哪个位置读来的"; 若**搜不到**, 则强结论: 它不是从图案流搬来的。

判读原理: 图案流是**确定性**的 (xorshift64, 种子 0x9E3779B97F4A7C15, 先取后推进),
所以拿到 (II, GG) 就能反查 "GG 这个值究竟来自图案流的哪个位置":
  k = j - II, k=0  => 该位置的值本身错了 (位级损坏 / 混合值)
  k<0             => 收到的是**更早**的值 (陈旧/重复)
    k = -1        => 重复上一字节        (字节级搬移: mac_rx_64 的 dline/wreg/hwreg)
    k = -8 / -16  => 陈旧一个/两个整字   (字级搬移: 帧缓冲/发射字寄存器)
    k = -PLEN     => **上一帧同偏移**     (帧缓冲 u_uf 的写没落地/写错址 —— 最想要的签名)
  k>0             => 收到的是**更晚**的值 (丢字节/丢字 => 流超前)

用法:
  # 直接给三个数
  python tools/rxp_classify.py --ii 12345 --gg 5F --ee 1A --paylen 1472
  # 或粘一整行 UART 状态行 (自动解析)
  python tools/rxp_classify.py --line "P5B1 ST=1 NX=... II=00003039 GG=5F EE=1A ..."
  # 只看不带板子时的自检
  python tools/rxp_classify.py --selftest

(注意: 速率测试一律用 C++ tools/cpp_peer/peer.exe; 本脚本只做判据解析, 不测速率。)
"""
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

MASK64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15
PAYLEN_DEFAULT = 1472


def xs_next(s):
    s ^= (s << 13) & MASK64
    s ^= s >> 7
    s ^= (s << 17) & MASK64
    return s & MASK64


def pattern(n):
    """图案流前 n 字节 (先取后推进)。"""
    s = SEED
    out = bytearray(n)
    for i in range(n):
        out[i] = (s >> 24) & 0xFF
        s = xs_next(s)
    return out


def popcount(v):
    return bin(v & 0xFF).count("1")


def word_search(ii, gw, paylen, lane=0, window=200000):
    """整字溯源: 在图案流里找 GW 这 8 个字节 (8 字节 ⇒ 近似唯一)。

    ⚠️ 两个必须小心的点 (独立审查指出, 都是"看起来很确凿其实误导"的类型):
    1. **字边界 = 收到字的边界**, 不是 `ii - ii%8`。RTL 用的是前者; 两者只有在
       "每帧载荷 ≡ 0 mod 8" 时才相同 (板级 1472 / 512 都是 ✓)。本函数用
       `base = ii - lane`, lane 由调用方从 `GW^EW` 的最低非零 lane 推出。
    2. **无效 lane 是 0 掩码** (lane >= popcount(tkeep))。若载荷不是 8 的倍数,
       末字会带零尾 —— 那时**不能**要求 8 字节精确相等, 否则会把"有效 lane 逐字节
       就是图案字节"误判成"不是从图案流搬来的" (假强结论)。这里先按整字精确匹配,
       不中再按"尾部全零 lane 当通配"重试, 并把用的是哪一种**明说出来**。
    """
    lo = max(0, ii - window)
    pat = pattern(ii + window + 8)
    wb = [(gw >> (56 - 8 * i)) & 0xFF for i in range(8)]      # lane0 = MSB
    base = ii - lane
    print("-" * 72)
    print("整字溯源 (GW 的 8 个字节在图案流里的落点; 8 字节 ⇒ 近似唯一):")
    print("  锚点 base = II - lane = %d - %d = %d (收到字的字边界)" % (ii, lane, base))

    def scan(mode):
        out = []
        n = 8
        if mode == "wild":                      # 尾部全零 lane 当通配
            while n > 0 and wb[n - 1] == 0:
                n -= 1
            if n == 0:
                return []
        for j in range(lo, min(len(pat) - 8, ii + window)):
            if mode == "exact":
                if bytes(pat[j:j + 8]) == bytes(wb):
                    out.append(j)
            else:
                if bytes(pat[j:j + n]) == bytes(wb[:n]):
                    out.append(j)
        return out

    hits = scan("exact")
    mode = "整字 8 字节精确匹配"
    if not hits and any(x == 0 for x in wb[1:]):
        h2 = scan("wild")
        if h2:
            hits, mode = h2, "**尾部全零 lane 当通配** (该字是部分字, 无效 lane 被 RTL 掩成 0)"
    print("  匹配方式:", mode)
    if not hits:
        print("  **两种方式都搜不到** ⇒ 收到的这个字**不是图案流里任何一个干净字的副本**。")
        print("  ⚠️ 注意 GW 必然含失配 lane, 所以:")
        print("     · 搜**到** ⇒ 整字被换成了**另一个干净字** (整字替换) ⇒ 溯源就是它的来源;")
        print("     · 搜**不到** ⇒ **不是整字替换** ⇒ 损坏是 lane 级/位级/多源混合,")
        print("       不是「把别处的整字搬过来」。这两条是互斥的强结论。")
        print("  ⚠️ 前提: 该字是满字 (帧载荷是 8 的倍数时恒成立; 板级 1472/512 都满足)。")
    for j in hits:
        k = j - base
        tag = ""
        if k == 0:            tag = "  <== 就是本字 (该字整体被改)"
        if k == -8:           tag = "  <== 陈旧一个字"
        if k == -paylen:      tag = "  <== ★上一帧同偏移的字"
        if k == +paylen:      tag = "  <== ★★**下一帧同偏移的字** (板级 v1 签名预测!)"
        if k == -2 * paylen:  tag = "  <== 上上帧同偏移的字"
        if k % 8 == 0 and not tag: tag = "  <== 整字对齐"
        print("   pos=%d  k(base)=%+d  k(II)=%+d%s" % (j, k, j - ii, tag))
    if hits:
        print("  ⇒ **整字替换**: 收到的字 = 图案流在 pos 处的干净字 (上面标的 k 即来源偏移)")
    return hits


def classify(ii, gg, ee, paylen, window=8192, gw=None, ew=None):
    pat = pattern(ii + window + 1)
    exp = pat[ii]
    print("=" * 72)
    print("II = %d   (帧 %d, 帧内偏移 %d, 字内 lane %d)"
          % (ii, ii // paylen, ii % paylen, ii % 8))
    print("EE = 0x%02X   GG = 0x%02X   PP(前一字节) = 0x%02X"
          % (ee, gg, pat[ii - 1] if ii > 0 else 0))
    print("校验: 图案流在 II 处的值 = 0x%02X  %s"
          % (exp, "== EE ✓ (II 与 EE 自洽)" if exp == ee else "!! != EE ✗ (II/EE 不自洽, 先查仪器)"))

    x = gg ^ ee
    pc = popcount(x)
    print("GG^EE = 0x%02X  popcount = %d" % (x, pc))
    if pc == 0:
        print("  ⇒ 值相同却没判匹配? 不可能 —— 读数有问题。")
    elif pc == 1:
        print("  ⇒ **单比特翻转** (寄存器位级/采样); 也可能是「混合值」里的单 bit 巧合。")
    elif pc == 2:
        print("  ⇒ 双比特翻转 / 两处独立位错。")
    else:
        print("  ⇒ 多比特错 —— 更像**整字节替换**(取到了别处的整字节)而非位翻转。")

    print("-" * 72)
    # ---- 关键假设直接判 (GG 是否恰好等于某个有物理含义位置的图案值) ----
    def eq(k):
        j = ii + k
        return 0 <= j < len(pat) and pat[j] == gg
    table = [
        (0,      "该位置自身被改 (位级损坏)",        "位级"),
        (-1,     "重复上一字节 (字节级搬移)",        "dline/wreg/hwreg"),
        (-8,     "陈旧一个整字 (字级搬移)",          "字寄存器/帧缓冲"),
        (-16,    "陈旧两个整字",                     "字寄存器/帧缓冲"),
        (-paylen,"**上一帧同偏移** (帧缓冲陈旧字)",  "u_uf 写未落地/写错址"),
        (+1,     "重复了下一个值 (流滞后1B)",        "—"),
        (+8,     "流超前一个整字 (丢字)",            "丢字"),
        (+paylen,"来自下一帧同偏移",                 "—"),
    ]
    print("关键假设逐条判 (GG 是否恰等于该位置的图案值):")
    for k, desc, src in table:
        mark = "命中 ★" if eq(k) else "  --  "
        print("   k=%+6d  %s  %s   [%s]" % (k, mark, desc, src))

    hits = []
    lo = max(0, ii - window)
    hi = min(len(pat) - 1, ii + window)
    for j in range(lo, hi + 1):
        if pat[j] == gg:
            hits.append(j - ii)
    if not hits:
        print("在 II±%d 窗口内**没有任何位置**的图案值等于 GG。" % window)
        print("  ⇒ 该值不是图案流里搬来的 ⇒ 位级损坏/多源混合, 不是搬移/陈旧。")
    else:
        print("GG 等于图案流下列位置的值 (k = j - II, PAYLEN=%d):" % paylen)
        for k in hits:
            tag = ""
            if k == 0:
                tag = "  <== k=0 (该位置自身被改)"
            if k == -1:
                tag = "  <== ★重复上一字节 (字节级搬移)"
            if k == -8 or k == -16:
                tag = "  <== ★陈旧整字 (字级搬移)"
            if k == -paylen:
                tag = "  <== ★★★ 上一帧同偏移 (帧缓冲 u_uf 写未落地/写错址)"
            if k == 8 or k == 16:
                tag = "  <== 流超前整字 (丢字)"
            if k == paylen:
                tag = "  <== 来自下一帧同偏移"
            if abs(k) > 0 and abs(k) % 8 == 0 and not tag:
                tag = "  <== 整字对齐"
            print("   j=%d  k=%+d%s" % (ii + k, k, tag))
        print("(共 %d 个候选 —— 单字节值在 256 里必重复, 故候选天然成群; "
              "以上「关键假设」表才是判据)" % len(hits))
        near = [k for k in hits if abs(k) <= 64]
        if near:
            print("  ⇒ 最近候选: k=%+d (幅值 <=64)" % min(near, key=abs))
    if gw is not None:
        lane = 0
        if ew is not None:
            x = gw ^ ew
            if x:
                # 最低非零 lane: lane0 = [63:56] ⇒ 找最高位的非零 bit 所在字节
                lane = 7 - ((x.bit_length() - 1) // 8)
            print("首失配 lane = %d  (由 GW^EW 的最低非零 lane 推出)" % lane)
            # ---- 行内自洽审计 (最便宜的护栏, 先做再解读机制) ----
            gb = (gw >> (56 - 8 * lane)) & 0xFF
            eb = (ew >> (56 - 8 * lane)) & 0xFF
            ok1 = (gb == gg); ok2 = (eb == ee)
            print("自洽: lane8(GW,lane)=%02X %s GG=%02X ; lane8(EW,lane)=%02X %s EE=%02X"
                  % (gb, "==" if ok1 else "!! !=", gg, eb, "==" if ok2 else "!! !=", ee))
            if not (ok1 and ok2):
                print("  ⚠️ **GW/EW 与 GG/EE 不自洽** ⇒ 先查仪器/读数, 别解读机制。")
        word_search(ii, gw, paylen, lane)
    print("=" * 72)


def v3_analyze(d, ii, paylen):
    """v3 帧边界记账 + 写侧整字指纹的判读 (见 ISSUE §14.4)。

    ⚠️ 字段偏移以 ISSUE §14.2 的**实测表**为准: 实现 agent 的报告表从 FR 起错位一个字段
       (它按"模板含 WD="算, 而 WD 只做成了端口、没显示)。
    """
    def g(k):
        return int(d[k], 16) if k in d else None
    ned = paylen // 8                      # 每帧字数
    WPW = 0x1FF                            # u_uf AW=9 ⇒ 9 位槽号
    print("=" * 72)
    print("v3 帧边界记账判读 (每帧应为 %d 字)" % ned)
    for k in ("SW","SF","SM","FR","FW","FO","FH","FS","FN","PR","PW","PH",
              "LR","LW","LO","LH","RC","VC","VX","VS","VR","VN"):
        if k in d:
            print("   %-3s = %s" % (k, d[k]))
    fn, fr, pr, fw, fo = g("FN"), g("FR"), g("PR"), g("FW"), g("FO")
    sf, sm = g("SF"), g("SM")
    print("-" * 72)
    # 1) 记录描述的是哪一帧 (独立审查: 9 拍错位 + 同拍交叠都是真会发生的)
    rec_ok = None
    if fn is not None:
        want = ii // paylen
        rec_ok = (fn == want)
        if fn == want:
            print("1) FN=%d == II/paylen=%d ✓ 记录描述的就是失配帧" % (fn, want))
        elif fn == want + 1:
            print("1) FN=%d == II/paylen+1=%d ⚠️ 记录描述的是**下一帧** (帧首拍晚于失配字所属帧)")
            print("     ⇒ 后续 3)/4) 的帧首类判据**不可用**; 只有 2) 的差额与 5) 的回卷判据仍有效")
        else:
            print("1) FN=%d 与 II/paylen=%d 不差 0 也不差 1 ⇒ **对不上, 先查仪器, 别解读机制**" % (fn, want))
    # 2) rptr 步进
    if fr is not None and pr is not None:
        step = (fr - pr) & WPW
        if step == ned:
            print("2) FR-PR = %d ✓ = 每帧字数 (%d)" % (step, ned))
        elif step == 0 and fn is not None and ii // paylen == fn - 1:
            print("2) FR-PR = 0 **但 FN = 失配帧+1** ⇒ **同拍交叠角** (ds_cap 恰落在下一帧帧首拍):")
            print("     记录自相矛盾(FR 是上一帧、FN 是新帧) —— **不是指针级缺陷**, 本轮帧首类判据作废")
        else:
            print("2) FR-PR = %d ### 不是 %d ⇒ **读者跳帧或重读帧 (指针级缺陷)**" % (step, ned))
    # 3) 槽号
    if fr is not None and sf is not None:
        print("3) FR[8:0]=%d vs SF=%d  %s" % (fr & WPW, sf,
              "✓ 读者 rptr 就在该帧首字被写入的槽上" if (fr & WPW) == sf else
              "### 不等 ⇒ **读者不在该帧首字所在槽 ⇒ 槽级坐实「提前一帧」**"))
    if fo is not None:
        print("   FO=%d  %s" % (fo, "✓ 在 [184,512]" if ned <= fo <= 512 else "### 越界 ⇒ 占用记账异常"))
    # 4) 决定性分叉 —— **先过两道闸, 否则会给出"第三值"的假结论**
    gw, ew, sw = g("GW"), g("EW"), g("SW")
    if sw is not None and gw is not None and ew is not None:
        if sm != 1:
            print("4) **分叉不可用**: SM=%s != 1 ⇒ 写侧表项无效 (抓不到 1..7 内的提交)" % sm)
            print("   ⇒ 本轮此路不通, 不要从 SW 下任何结论。")
            sw = None
        elif rec_ok is False:
            print("4) **分叉不可用**: 记录描述的是另一帧 (FN≠II/paylen) ⇒ SW 与 GW 不同源 ⇒ 会是假「第三值」。")
            sw = None
    if sw is not None and gw is not None and ew is not None:
        print("4) **决定性分叉** SW vs GW/EW (SM=1 且记录帧一致, 前提已过):")
        print("     SW == GW  %s" % ("是" if sw == gw else "否"))
        print("     SW == EW  %s" % ("是" if sw == ew else "否"))
        if sw == gw and sw != ew:
            print("     ⇒ **写进去时就已经是坏字 ⇒ 损坏在 u_uf 上游** (udp_rx/mac_rx_64/FCS 盲区); 指针记录不必再看")
        elif sw == ew and sw != gw:
            print("     ⇒ **写是干净的 ⇒ 损坏在 u_uf 内或读时**; 由 2)/3)/5) 定案")
        elif sw == gw == ew:
            print("     ⇒ SW 同时等于两者? 不可能 (GW!=EW) ⇒ **读数有问题**")
        else:
            print("     ⇒ 第三值 ⇒ 不是从图案流搬来的字, 照实报 (先确认 SM=1)")
    # 5) 回卷
    rc, vc = g("RC"), g("VC")
    if rc is not None:
        print("5) 回卷: RC=%s VC=%s  %s" % (rc, vc,
              "无违例 (回卷从未吃掉已提交数据)" if vc == 0 else "### **有违例** ⇒ 看 VX(=184 即吃掉整整一帧) / VS / VR 是否落在被吃区间"))
    vx, vs, vr = g("VX"), g("VS"), g("VR")
    if vc and vs is not None and vx is not None and vr is not None:
        lo, hi = vs, (vs + vx + (g("FH") or 0)) & WPW
        print("   被吃区间 ≈ [%d, %d); VR=%d  %s" % (lo, hi, vr,
              "**落在区间内 ⇒ 读者读了被覆写的区域**" if lo <= (vr % (WPW+1)) < hi else "不在区间内"))
    print("=" * 72)


def parse_line(line):
    d = {}
    for k, v in re.findall(r"([A-Z]{2})=([0-9A-Fx]+)", line):
        d[k] = v
    return d


def selftest():
    """无板自检: 造 4 个合成坏值, 看分类器能不能各自指回正确的 k。"""
    pat = pattern(20000)
    cases = [(5000, 0, None), (5000, -1, None), (5000, -8, None), (5000, -1472, None)]
    ok = 0
    for ii, k, _ in cases:
        gg = pat[ii + k] if k else (pat[ii] ^ 0x40)
        hits = []
        for j in range(max(0, ii - 8192), ii + 8193):
            if pat[j] == gg:
                hits.append(j - ii)
        want = k if k else 0
        good = (want in hits) if k else (0 not in hits)
        ok += good
        print("selftest ii=%d 注入 k=%+d : 候选=%s  %s"
              % (ii, k, hits[:6], "OK" if good else "FAIL"))
    print("selftest: %d/%d" % (ok, len(cases)))
    return 0 if ok == len(cases) else 1


def main():
    argv = sys.argv[1:]
    if "--selftest" in argv:
        return selftest()
    paylen = PAYLEN_DEFAULT
    if "--paylen" in argv:
        paylen = int(argv[argv.index("--paylen") + 1])
    if "--line" in argv:
        d = parse_line(argv[argv.index("--line") + 1])
        if not all(k in d for k in ("II", "GG", "EE")):
            print("状态行里没解析到 II/GG/EE —— 用的是 RXP_DIAG 位流吗?")
            print("解析到的字段:", sorted(d))
            return 2
        gw = int(d["GW"], 16) if "GW" in d else None
        ew = int(d["EW"], 16) if "EW" in d else None
        classify(int(d["II"], 16), int(d["GG"], 16), int(d["EE"], 16), paylen, gw=gw, ew=ew)
        if "SW" in d:
            v3_analyze(d, int(d["II"],16), paylen)
        if "BA" in d:
            print("行内其余字段: BA=%s BB=%s BC=%s DD=%s  (popcount 形状, 整轮聚合)")
            print("              OZ=%s OL=%s OM=%s OH=%s  (帧内偏移分桶: 0 / 1-7 / 8-63 / >=64)"
                  % (d.get("OZ"), d.get("OL"), d.get("OM"), d.get("OH")))
            print("  ⚠️ II/GG/EE/PP/GW/EW 是**首失配单点快照**; BA/BB/BC/DD/OZ/OL/OM/OH 是**整轮聚合**。")
            try:
                umm = int(d["MM"], 16)
                s1 = int(d["BA"],16)+int(d["BB"],16)+int(d["BC"],16)
                s2 = int(d["OZ"],16)+int(d["OL"],16)+int(d["OM"],16)+int(d["OH"],16)
                print("  ★自洽审计: BA+BB+BC=%d %s UMM=%d ; OZ+OL+OM+OH=%d %s UMM=%d"
                      % (s1, "==" if s1==umm else "!! !=", umm,
                         s2, "==" if s2==umm else "!! !=", umm))
                if not (s1==umm and s2==umm):
                    print("     ⚠️ 不等式 ⇒ 先查仪器/读数, 别解读机制。")
                if int(d["OZ"],16)==0:
                    print("     ⚠️ OZ=0 ⇒ 本轮**没有**帧首字节失配 (与 §11.6 的签名不符, 要单独解释)。")
            except (KeyError, ValueError):
                pass
        return 0
    need = ("--ii", "--gg", "--ee")
    if all(o in argv for o in need):
        g = lambda o: int(argv[argv.index(o) + 1], 16)
        gw = int(argv[argv.index("--gw") + 1], 16) if "--gw" in argv else None
        ew = int(argv[argv.index("--ew") + 1], 16) if "--ew" in argv else None
        classify(g("--ii"), g("--gg"), g("--ee"), paylen, gw=gw, ew=ew)
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
