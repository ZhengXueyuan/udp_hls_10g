#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""rxp_round_check.py — RXP 板级读数的**前置闸** (ISSUE §12.6 的 P1-P3 自动化)。

为什么需要它: 2026-09-26 我做长跑对照时, 烧录脚本指向了一个正在被构建重建的位流路径
(构建 `create_project -force` 会先删再重建) ⇒ **复位根本没发生** ⇒ 图案相位丢失 ⇒
三轮 UMM 都是 ~1e8 (= 全失配) 且每轮 `II` 完全相同。**仪器的自洽不变式当时全部成立**
(它查的是"仪器自洽", 查不出"板子没复位") ⇒ 我自己的分析脚本对着垃圾打印了一句确信结论。

⇒ 凡是要从一行读数下结论, **先过这道闸**。任何一条不过 ⇒ 脚本拒绝输出派生结论。

用法:
  python tools/rxp_round_check.py --line "<整行>" --sent-bytes 33554432 --sent-frames 22796 --paylen 1472
  # 跑量不同时用 --bytes-ref 按比例放缩, 或直接给 --umm-lo/--umm-hi。

**P3 区间的标定原则 (2026-09-27 修正, 原标定是错的 —— 见下)**:
  要分开的两个模态是「健康」与「没复位」, 相差 **~350x**:
    健康   : 18 轮实测 UMM ∈ [2940, 23993]  (0.035% ~ 0.286%, 跨度 8.2x)
    没复位 : UMM ≈ 送出字节数 (8388608) 或 ~1e8  —— 即 ~100% 全失配
  所以区间必须按「数量级」设, 而不是按「样本极值」设。
  原默认 [2940, 21432] 是那 18 轮的**最小/第二大值**, 有两个硬伤:
    ① 下界钉在样本最小值上 ⇒ 按构造, 任何新低必然报警 (与现象是否变化无关);
    ② **上界 21432 低于实测到的 23993** ⇒ 它会**否掉一个已知良好的 v2 轮次**
       (那轮正是 §13 机制结论的数据之一)。会否掉已知好数据的闸就是标定错了。
  新默认 [1000, 150000]: 下留 3x 余量、上留 6x 余量, 仍比病理模态低 56x。
"""
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass


def main():
    a = sys.argv[1:]
    def opt(k, d=None):
        return a[a.index(k) + 1] if k in a else d
    if "--line" not in a:
        print(__doc__); return 1
    d = dict(re.findall(r"([A-Z]{2})=([0-9A-Fx]+)", opt("--line")))
    def g(k):
        return int(d[k], 16) if k in d else None
    sent_b = int(opt("--sent-bytes", "8388608"))
    sent_f = int(opt("--sent-frames", "5699"))
    paylen = int(opt("--paylen", "1472"))
    ref_b  = int(opt("--bytes-ref", "8388608"))
    UMM, URB, URF = g("MM"), g("RB"), g("RF")
    UPC, UOV, UPA = g("PC"), g("OV"), g("PA")
    # 下界 = 0 (2026-09-27 修正): 原为 1000, 但 **UMM=0 是合法的"无损坏"读数**
    # —— 实测 100 Mbps 那轮 UMM=0 且 URB/URF 精确、UPC/OV/PA=0、II=0 ⇒ 自证有效。
    # 原下界的存在理由是"抓没复位", 但那个模态是 UMM ≈ 送出字节数, 由**上界**抓;
    # 而 URB/URF 精确 (P2) 已保证这一轮真的跑过 ⇒ 下界冗余, 且会否掉真实的零。
    umm_lo = int(opt("--umm-lo", str(int(0 * sent_b / ref_b))))
    umm_hi = int(opt("--umm-hi", str(int(150000 * sent_b / ref_b))))

    fails = []
    # ---- P1 仪器自洽 ----
    ba, bb, bc = g("BA"), g("BB"), g("BC")
    if None not in (ba, bb, bc, UMM) and ba + bb + bc != UMM:
        fails.append("P1 BA+BB+BC=%d != UMM=%d" % (ba + bb + bc, UMM))
    if None not in (g("OZ"), g("OL"), g("OM"), g("OH"), UMM) and \
       g("OZ") + g("OL") + g("OM") + g("OH") != UMM:
        fails.append("P1b OZ+OL+OM+OH != UMM")
    # ---- P2 收发口径 ----
    if URB != sent_b:
        fails.append("P2 URB=%s != 送出 %d  (**收字节数不精确 ⇒ 有丢帧/半帧**)" % (URB, sent_b))
    if URF != sent_f % 65536:
        fails.append("P2 URF=%s != 帧数 %d (mod 65536)" % (URF, sent_f))
    for k, v in (("UPC", UPC), ("UOV", UOV), ("UPA", UPA)):
        if v != 0:
            fails.append("P2 %s=%s != 0" % (k, v))
    # ---- P3 UMM 落在预期区间 ----
    if UMM is None:
        fails.append("P3 解析不到 UMM (键 MM)")
    elif not (umm_lo <= UMM <= umm_hi):
        fails.append("P3 UMM=%d 越出预期区间 [%d, %d] (数量级不符, 非健康模态; "
                     "**最可能是没复位 / 图案相位丢了** —— 相位丢时 UMM 会接近送出字节数 %d, "
                     "且每轮 II 相同)" % (UMM, umm_lo, umm_hi, sent_b))

    # ---- P4 (仅 v4 行): 新仪器的内部自洽 ----
    # NE 与 OZ 由同一表达式驱动 ⇒ 必须相等; 不等说明仪器坏了, 而不是机制变了。
    # EN/EO 口径: 记录数 EN 应 == min(事件数, 8); 若 EN < NE 而 EO=0, 那是静默丢弃。
    if "NE" in d:
        ne, nr, mr = g("NE"), g("NR"), g("MR")
        oz = g("OZ")
        if None not in (ne, oz) and ne != oz:
            fails.append("P4 NE=%s != OZ=%s (同一表达式驱动, 不等 ⇒ **仪器坏了**, 别解读机制)"
                         % (ne, oz))
        if None not in (ne, nr) and nr > ne:
            fails.append("P4 NR=%s > NE=%s (段数不可能多于事件数 ⇒ 仪器坏了)" % (nr, ne))
        if None not in (nr, mr) and mr > ne:
            fails.append("P4 MR=%s > NE=%s (最长段不可能长于事件数 ⇒ 仪器坏了)" % (mr, ne))
        en, eo = g("EN"), g("EO")
        if None not in (en, eo, ne):
            if en != min(ne, 8):
                fails.append("P4 EN=%s != min(NE=%s, 8)=%d (记录条数口径不符 ⇒ 仪器坏了)"
                             % (en, ne, min(ne, 8)))
            if en < ne and eo == 0:
                fails.append("P4 EN=%s < NE=%s 但 EO=0 ⇒ **有事件被静默丢弃** (溢出标志没置)"
                             % (en, ne))
        # 回卷/丢字会污染**整组**帧级字段 (app 的 LFSR 断流后每帧首字节都失配) ⇒ 显式降级提示。
        # ⚠️ 审查曾建议把作废条件扩到 UPC/UOV/UPA。**实测后确认那条是冗余的**: P2 已经对
        #    UPC/UOV/UPA 硬失败 (见上), 所以**过闸的轮次必然三者全 0、且 URB/URF 精确**
        #    ⇒ 丢帧/断流在过闸轮次里不可能发生。下面仍带上它们, 只是**防御性**写法,
        #    真正的把关在 P2。别再把它当成"补上了一个缺口"。
        rb = [k for k in ("CN", "RD", "WF", "RL") if g(k)]
        dr = [n for n, v in (("UPC", UPC), ("UOV", UOV), ("UPA", UPA)) if v]
        if rb or dr:
            why = "/".join(rb + dr)
            print("  ⚠️ P4 作废提示: %s 非 0 ⇒ app 的 LFSR 流已断/有回卷 ⇒ "
                  "**NE/OZ/QA..QH 与 NR/MR 全体不可用于结论**, §17.7 的环相位判据同时作废。"
                  % why)

    print("读数: URB=%s UMM=%s URF=%s UPC/OV/PA=%s/%s/%s II=%s" % (
        URB, UMM, URF, UPC, UOV, UPA, d.get("II")))
    print("闸: 期望 UMM ∈ [%d, %d] (按送出 %d 字节 / 参考 %d 放缩)" % (umm_lo, umm_hi, sent_b, ref_b))
    if fails:
        print("\n*** 前置闸未过 —— 拒绝输出任何派生结论 ***")
        for f in fails:
            print("   ✗ " + f)
        return 2
    print("\n✓ 前置闸全过 —— 这一轮读数可用于结论")
    return 0


if __name__ == "__main__":
    sys.exit(main())
