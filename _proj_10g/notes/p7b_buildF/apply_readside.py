#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 构建 F —— **读侧全部默认值同步** 67 字/BID 0x19 → 70 字/BID 0x1A
   + 未实现地址 0x12C → 0x138 + `GEOM_TIERS` 两处各加一行 + 取数器 `NAME[]` 补到新末字
   + 所有读侧脚本默认值 + sim 侧 TB 的 BID/未实现地址 + 反例台架夹具几何。
   显式清单 (每条断言命中数; 不做任何通配替换); 行尾用文件自身的风格。
   形状照 `_proj_10g/notes/p7b_buildE/apply_readside.py`。
   ⚠️ 第五次扩窗, 历史主要失分点 = "五处只改三处" ⇒ 本清单**逐处列出**, 不靠记忆。
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def rd(p):
    b = open(p, "rb").read()
    return b, (b"\r\n" if b.count(b"\r\n") else b"\n")


EDITS = []


def E(rel, old, new, n=1):
    EDITS.append((rel, old, new, n))


# ===========================================================================
# ① 两个 j6 台架脚本: NW / EXPECT_BID / GEOM_TIERS 加一行 (旧档一律保留)
# ===========================================================================
for f in ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
          "_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh"):
    # ⚠️ 锚点带尾换行: 同文件 :44/:38 的**注释**里也有 `NW=${NW:-67}`（后跟反引号）⇒
    #    不带换行会命中 2 处（第一版实测 hits=2/1）。
    E(f, "NW=${NW:-67}\n", "NW=${NW:-70}\n", 1)
    E(f,
      '"67|0x00000019|61 62|构建 E (2026-10-10) 67 字 / BID 0x19 (W66 = tcp_tx_frame.stat_winstall)"',
      '"70|0x0000001A|61 62|构建 F (2026-10-10) 70 字 / BID 0x1A (W67/W68/W69 = 三个纯观测仪器)"\n'
      '  "67|0x00000019|61 62|构建 E (2026-10-10) 67 字 / BID 0x19 (W66 = tcp_tx_frame.stat_winstall)"', 1)

E("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}   # 2026-10-10 构建 E (67 字; 原 0x00000018 = 构建 D / 0x00000017 = 构建 C / 0x11 = r6-fix)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}   # 2026-10-10 构建 F (70 字; 原 0x00000019 = 构建 E / 0x18 = 构建 D / 0x17 = 构建 C)", 1)
E("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}   # 2026-10-10 构建 E (67 字; 原 0x00000018 = 构建 D / 0x17 = 构建 C / 0x09 = WU 二轮)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}   # 2026-10-10 构建 F (70 字; 原 0x00000019 = 构建 E / 0x18 = 构建 D / 0x09 = WU 二轮)", 1)

# ===========================================================================
# ② 取数器 p7b_snap.sh (NW / BID / 未实现地址注释 / NAME[67..69])
# ===========================================================================
E("_proj_pcie/p7b_biz/p7b_snap.sh", "NW=${NW:-67}", "NW=${NW:-70}", 1)
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 67 ⇒ 0x12C (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 70 ⇒ 0x138 (67 ⇒ 0x12C; 65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)", 1)
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}",
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}", 1)
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  "[65]=mac_tx_idle          [66]=tx_stat_winstall\n",
  "[65]=mac_tx_idle          [66]=tx_stat_winstall\n"
  "# ⭐ 构建 F (2026-10-10): W67/W68/W69 —— 三个**纯观测**仪器 (把 `L` 拆开)。真值源 =\n"
  "#    `board/wrapper_p4.v` 装配段 / `_proj_10g/notes/P7B_L_INSTRUMENT_DESIGN.md` §2:\n"
  "#      W67 = tcp_tx_frame.stat_winstall_cap (板帽侧等窗拍数) /\n"
  "#      W68 = tcp_rx.stat_ack_adv (推进 snd_una 的 ACK 次数 = L 的分母) /\n"
  "#      W69 = tcp_tx_frame.o_win_at_winstall (最近一次等窗拍 {在飞, 有效窗} 锁存;\n"
  "#            ⚠️ **仅当同窗 ΔW66 > 0 时才有效** —— 否则是上一次的陈旧值)。\n"
  "[67]=tx_winstall_cap      [68]=rx_stat_ack_adv     [69]=tx_win_at_winstall\n", 1)
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 67 字 / BID 0x19**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ 构建 E (2026-10-10): 66 → **67** (W66 = tcp_tx_frame.stat_winstall; 未实现地址 0x128 → **0x12C**)。",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 70 字 / BID 0x1A**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ 构建 F (2026-10-10): 67 → **70** (W67/W68/W69 = 三个纯观测仪器; 未实现地址 0x12C → **0x138**)。\n"
  "#   ⭐ 构建 E (2026-10-10): 66 → **67** (W66 = tcp_tx_frame.stat_winstall; 未实现地址 0x128 → **0x12C**)。", 1)

# ===========================================================================
# ③ _proj_pcie 三个读侧验收脚本
# ===========================================================================
E("_proj_pcie/p6e_snap_check.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}       # ⛔ 2026-10-10 构建 E: 原默认 0x00000018 (构建 D 66 字) / 0x17 (构建 C) / 0x0A (Stage C)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}       # ⛔ 2026-10-10 构建 F: 原默认 0x00000019 (构建 E 67 字) / 0x18 (构建 D) / 0x0A (Stage C)", 1)
E("_proj_pcie/p6e_snap_check.sh",
  "SNAP_WORDS=${SNAP_WORDS:-67}",
  "SNAP_WORDS=${SNAP_WORDS:-70}", 1)
E("_proj_pcie/p6e_snap_check.sh",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 67 ⇒ 0x12C (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 70 ⇒ 0x138 (67 ⇒ 0x12C; 65 ⇒ 0x124; 63 ⇒ 0x11C; 51 ⇒ 0xEC)", 1)

E("_proj_pcie/p7b_gate4_accept.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}      # 构建 E = 0x19 (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x18 = 构建 D / 17 = 构建 C)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}      # 构建 F = 0x1A (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x19 = 构建 E / 0x18 = 构建 D)", 1)
E("_proj_pcie/p7b_gate4_accept.sh",
  "SNAP_WORDS=${SNAP_WORDS:-67}",
  "SNAP_WORDS=${SNAP_WORDS:-70}", 1)
E("_proj_pcie/p7b_gate4_accept.sh",
  "# 67 ⇒ 0x12C (66 ⇒ 0x128; 65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "# 70 ⇒ 0x138 (67 ⇒ 0x12C; 66 ⇒ 0x128; 65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)", 1)

# ---- p6e_snap_selftest_fix2.sh (假板子: 尾段随几何走) ----
E("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "# ⚠️ 假板子的**几何必须与现役 RTL 同代** (= **67 字 / 未实现 0x12C**; 2026-10-10 构建 E;\n"
  "#    原句 = 66 字 / 0x128 (P7B-A7 构建 D);",
  "# ⚠️ 假板子的**几何必须与现役 RTL 同代** (= **70 字 / 未实现 0x138**; 2026-10-10 构建 F;\n"
  "#    原句 = 67 字 / 0x12C (构建 E) / 66 字 / 0x128 (P7B-A7 构建 D);", 1)
E("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "  0X04) V=\\${FAKE_BID:-0x00000019};;   # 构建 E = 0x19 (⛔ 原 0x18 = 构建 D / 0x17 = 构建 C / 0x0A = Stage C);",
  "  0X04) V=\\${FAKE_BID:-0x0000001A};;   # 构建 F = 0x1A (⛔ 原 0x19 = 构建 E / 0x18 = 构建 D / 0x0A = Stage C);", 1)
E("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "  0X128) V=0x00000000;;                                       # W66 tcp_tx_frame.stat_winstall (67 字起; 构建 E)\n"
  "  0X12C) V=0xffffffff;;                                       # 未实现地址 (67 字; … -> 0x124 -> 0x128 -> **0x12C**)",
  "  0X128) V=0x00000000;;                                       # W66 tcp_tx_frame.stat_winstall (67 字起; 构建 E)\n"
  "  0X12C) V=0x00000000;;                                       # W67 tcp_tx_frame.stat_winstall_cap (70 字起; 构建 F)\n"
  "  0X130) V=0x00000000;;                                       # W68 tcp_rx.stat_ack_adv (70 字起; 构建 F)\n"
  "  0X134) V=0x00000000;;                                       # W69 tcp_tx_frame.o_win_at_winstall (70 字起; 构建 F)\n"
  "  0X138) V=0xffffffff;;                                       # 未实现地址 (70 字; … -> 0x12C -> **0x138**)", 1)

# ---- p7b_gate4_selftest.sh (SW 档 + 假字表) ----
E("_proj_pcie/p7b_gate4_selftest.sh",
  "SW=${SNAP_WORDS:-67}",
  "SW=${SNAP_WORDS:-70}", 1)
E("_proj_pcie/p7b_gate4_selftest.sh",
  "#   SW ≥ 67 (2026-10-10 构建 E 起) ⇒ 0x11C/0x120/0x124/0x128 也是**窗口内的真字**,\n"
  "#     `FAKE_UNIMPL` 挪到 **0x12C**;\n",
  "#   SW ≥ 70 (2026-10-10 构建 F 起) ⇒ 0x12C/0x130/0x134 也是**窗口内的真字**,\n"
  "#     `FAKE_UNIMPL` 挪到 **0x138**;\n"
  "#   SW ≥ 67 (构建 E) ⇒ 0x11C/0x120/0x124/0x128 是窗口内真字 ⇒ `FAKE_UNIMPL` 在 **0x12C**;\n", 1)
E("_proj_pcie/p7b_gate4_selftest.sh",
  "if [ \"$SW\" -ge 67 ]; then\n"
  "  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)\n"
  "  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)\n"
  "  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)\n"
  "  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)\n"
  "  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)\n"
  "  0X128) V=0;;     # W66 tcp_tx_frame.stat_winstall (窗口门停顿拍数, 建 E 新增)\n"
  "  0X12C) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (67 字)'\n",
  "if [ \"$SW\" -ge 70 ]; then\n"
  "  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)\n"
  "  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)\n"
  "  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)\n"
  "  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)\n"
  "  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)\n"
  "  0X128) V=0;;     # W66 tcp_tx_frame.stat_winstall (窗口门停顿拍数, 建 E 新增)\n"
  "  0X12C) V=0;;     # W67 tcp_tx_frame.stat_winstall_cap (板帽侧等窗拍数, 建 F 新增)\n"
  "  0X130) V=0;;     # W68 tcp_rx.stat_ack_adv (推进 snd_una 的 ACK 次数, 建 F 新增)\n"
  "  0X134) V=0;;     # W69 tcp_tx_frame.o_win_at_winstall (等窗拍操作点锁存, 建 F 新增)\n"
  "  0X138) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (70 字)'\n"
  "elif [ \"$SW\" -ge 67 ]; then\n"
  "  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)\n"
  "  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)\n"
  "  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)\n"
  "  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)\n"
  "  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)\n"
  "  0X128) V=0;;     # W66 tcp_tx_frame.stat_winstall (窗口门停顿拍数, 建 E 新增)\n"
  "  0X12C) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (67 字)'\n", 1)
E("_proj_pcie/p7b_gate4_selftest.sh",
  "  0X04) V=\\${FAKE_BID:-0x00000019};;",
  "  0X04) V=\\${FAKE_BID:-0x0000001A};;", 1)
E("_proj_pcie/p7b_gate4_selftest.sh",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x19** (构建 E 67 字 —— ⛔ 2026-10-10 同步轮: 原 0x18 = 构建 D 66 字 /",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1A** (构建 F 70 字 —— ⛔ 2026-10-10 同步轮: 原 0x19 = 构建 E 67 字 /", 1)

# ---- p7b_gate4_livefake.sh (假对端: W 列表长度 + BID 表) ----
E("_proj_pcie/p7b_gate4_livefake.sh",
  "        + [0] * 16          # W51..W66 = P7B-BIZ/WU/构建C/构建D/构建E 新增字 (accept 只要求窗口齐全 + 无 0xffffffff)\n"
  "        #   ⛔ 2026-10-10 (构建 E): 15 -> **16** —— 构建 E 的远端请求是 67 字 (`for i in seq 0 66`),\n"
  "        #     `W[i]` 只到 W65 ⇒ 不同步会 `IndexError` (假对端直接崩 = \"整台安静\")。\n",
  "        + [0] * 19          # W51..W69 = P7B-BIZ/WU/构建C/D/E/F 新增字 (accept 只要求窗口齐全 + 无 0xffffffff)\n"
  "        #   ⛔ 2026-10-10 (构建 F): 16 -> **19** —— 构建 F 的远端请求是 70 字 (`for i in seq 0 69`),\n"
  "        #     `W[i]` 只到 W66 ⇒ 不同步会 `IndexError` (假对端直接崩 = \"整台安静\")。\n"
  "        #   ⛔ 2026-10-10 (构建 E): 15 -> **16** —— 构建 E 的远端请求是 67 字 (`for i in seq 0 66`),\n"
  "        #     `W[i]` 只到 W65 ⇒ 不同步会 `IndexError` (假对端直接崩 = \"整台安静\")。\n", 1)
E("_proj_pcie/p7b_gate4_livefake.sh",
  "    #   ⛔ 2026-10-10 (构建 E): 加 **67 字那一代 = 0x19**; 兜底值同改 0x19 (现役代)。\n"
  "    bid = {67: \"0x00000019\", 66: \"0x00000018\", 65: \"0x00000017\", 63: \"0x0000000A\", 61: \"0x00000008\", 51: \"0x00000007\"}.get(nw, \"0x00000019\")",
  "    #   ⛔ 2026-10-10 (构建 E): 加 **67 字那一代 = 0x19**。\n"
  "    #   ⛔ 2026-10-10 (构建 F): 加 **70 字那一代 = 0x1A**; 兜底值同改 0x1A (现役代)。\n"
  "    bid = {70: \"0x0000001A\", 67: \"0x00000019\", 66: \"0x00000018\", 65: \"0x00000017\", 63: \"0x0000000A\", 61: \"0x00000008\", 51: \"0x00000007\"}.get(nw, \"0x0000001A\")", 1)

# ---- p7b_gate4_negctrl.sh (合成夹具: 几何 / W 数组尾 / 循环上界 / awk) ----
E("_proj_pcie/p7b_gate4_negctrl.sh",
  "# 几何: **67 字 (W0..W66)** —— 构建 E (2026-10-10, BID=0x19 / 未实现 0x12C);\n"
  "#       (原句: \"66 字 (W0..W65) —— P7B-A7 构建 D (2026-10-10, BID=0x18 / 未实现 0x128)\" = 历史代, 逐字保留于下)",
  "# 几何: **70 字 (W0..W69)** —— 构建 F (2026-10-10, BID=0x1A / 未实现 0x138);\n"
  "#       (原句: \"67 字 (W0..W66) —— 构建 E (2026-10-10, BID=0x19 / 未实现 0x12C)\" = 历史代, 逐字保留于下)\n"
  "#       (原句: \"66 字 (W0..W65) —— P7B-A7 构建 D (2026-10-10, BID=0x18 / 未实现 0x128)\" = 历史代, 逐字保留于下)", 1)
E("_proj_pcie/p7b_gate4_negctrl.sh",
  'echo "MAGIC 0x50360001"; echo "BID 0x00000019"; echo "MARKER 0xdeadbeef"   # 构建 D: 原 0x0000000A = Stage C   # Stage C: 原 0x00000009',
  'echo "MAGIC 0x50360001"; echo "BID 0x0000001A"; echo "MARKER 0xdeadbeef"   # 构建 F: 原 0x19 = 构建 E / 0x18 = 构建 D / 0x0A = Stage C', 1)
E("_proj_pcie/p7b_gate4_negctrl.sh",
  "                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)   # W51..W66 (构建 E: W66 = tcp_tx_frame.stat_winstall)\n"
  "    local i; for (( i = 0; i < 67; i++ )); do printf 'W%d 0x%X\\n' \"$i\" \"${V[$i]}\"; done\n",
  "                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
  "                0 0 0)   # W51..W69 (构建 F: W67/W68/W69 = 三个纯观测仪器)\n"
  "    local i; for (( i = 0; i < 70; i++ )); do printf 'W%d 0x%X\\n' \"$i\" \"${V[$i]}\"; done\n", 1)
E("_proj_pcie/p7b_gate4_negctrl.sh",
  "shift1(){ awk -v NW=67 ",
  "shift1(){ awk -v NW=70 ", 1)

# ===========================================================================
# ④ final_state.sh (未实现地址 + W66..W69 读数行 + 期望 BID)
# ===========================================================================
E("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  'echo "MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x12c) gen=$(( (s >> 16) & 0xffff ))"',
  'echo "MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x138) gen=$(( (s >> 16) & 0xffff ))"', 1)
E("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **67 字 (构建 E, 2026-10-10 起) ⇒ 0x12C** (word 75);\n"
  "#    66 字 (构建 D) = 0x128 (word 74); 65 字 (P7B-GAP9-TX) = 0x124 (word 73);",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **70 字 (构建 F, 2026-10-10 起) ⇒ 0x138** (word 78);\n"
  "#    67 字 (构建 E) = 0x12C (word 75); 66 字 (构建 D) = 0x128 (word 74); 65 字 = 0x124 (word 73);", 1)
E("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  'echo "W63=$(rd 0x11c) W64=$(rd 0x120) W65=$(rd 0x124)  # 构建 C: app 停滞计数; 构建 D: W65 = mac_tx_10g.stat_tx_idle"\n'
  'echo "W66=$(rd 0x128)  # 构建 E: W66 = tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数)"',
  'echo "W63=$(rd 0x11c) W64=$(rd 0x120) W65=$(rd 0x124)  # 构建 C: app 停滞计数; 构建 D: W65 = mac_tx_10g.stat_tx_idle"\n'
  'echo "W66=$(rd 0x128)  # 构建 E: W66 = tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数)"\n'
  'echo "W67=$(rd 0x12c) W68=$(rd 0x130) W69=$(rd 0x134)  # 构建 F: 板帽侧等窗拍数 / 推进 ACK 次数 / 等窗拍操作点锁存"', 1)
E("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000017}\n",
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}   # ⛔ 2026-10-10 构建 F (70 字); 原 0x17 = 构建 C\n", 1)

# ===========================================================================
# ⑤ sim 侧 TB (BID / 未实现地址) + p7b_chain
# ===========================================================================
E("sim/p6e_pcie/tb_p6e_pcie_counters.v",
  "chk(\"0b BUILD_ID (构建 E 67-word = 0x19; 原 66-word=0x18 / 65-word=17 / 63-word=9)\", v, 32'h00000019);",
  "chk(\"0b BUILD_ID (构建 F 70-word = 0x1A; 原 67-word=0x19 / 66-word=0x18 / 63-word=9)\", v, 32'h0000001A);", 1)
E("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "chk(\"2  BUILD_ID (构建 E 67 字=0x19; 原 66 字=0x18 / 65 字=17 / 63 字=9)\", v, 32'h00000019);",
  "chk(\"2  BUILD_ID (构建 F 70 字=0x1A; 原 67 字=0x19 / 66 字=0x18 / 63 字=9)\", v, 32'h0000001A);", 1)
E("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "        chk(\"9  未实现地址 0x12C ⇒ rresp = SLVERR\", {30'd0, u_dut.u_pcie_xdma.last_rresp}, 32'd2);",
  "        chk(\"9  未实现地址 0x138 ⇒ rresp = SLVERR\", {30'd0, u_dut.u_pcie_xdma.last_rresp}, 32'd2);", 1)
E("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "        u_dut.u_pcie_xdma.axil_read(32'h12C, v);",
  "        u_dut.u_pcie_xdma.axil_read(32'h138, v);", 1)
E("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "        // ⛔ 2026-10-10 (构建 E): 窗口 66 → **67 字** (`SNAP_NW_P6E = 67`) ⇒ 末字 W66 @ 0x128\n"
  "        //    ⇒ 未实现地址 = 0x20 + 4*67 = **0x12C** (word 75)。0x128 现在是窗口内的真字。",
  "        // ⛔ 2026-10-10 (构建 F): 窗口 67 → **70 字** (`SNAP_NW_P6E = 70`) ⇒ 末字 W69 @ 0x134\n"
  "        //    ⇒ 未实现地址 = 0x20 + 4*70 = **0x138** (word 78)。0x12C/0x130/0x134 现在是窗口内的真字。", 1)
E("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  "        u_dut.u_pcie_xdma.axil_read(32'h12C, v);\n        chk(\"7b 0x12C reads 0 no wrap\",",
  "        u_dut.u_pcie_xdma.axil_read(32'h138, v);\n        chk(\"7b 0x138 reads 0 no wrap\",", 1)
E("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  "\"axi_regs decode; 67-word bound (原 66 字/0x128, 65 字/0x124, 63 字/0x11C; 2026-10-10 订正)\");",
  "\"axi_regs decode; 70-word bound (原 67 字/0x12C, 66 字/0x128, 63 字/0x11C; 2026-10-10 订正)\");", 1)

# ===========================================================================
# ⑥ p7b_biz_win 三个守卫 (tb_biz_win.v / run_tb_biz_win.bat / run_xvlog_wrapper.bat)
#    / sim/p5wu_p1p2/run_xvlog_wrapper63.bat
# ===========================================================================
E("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "// tb_biz_win.v — P7B-BIZ 快照窗口的**逐字读回**门 (axi_regs @ SNAP_NW=67; 构建 E 起;",
  "// tb_biz_win.v — P7B-BIZ 快照窗口的**逐字读回**门 (axi_regs @ SNAP_NW=70; 构建 F 起;", 1)
E("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "    localparam integer NW = 67;  // = wrapper 的 SNAP_NW_P6E (构建 E, 2026-10-10; 原 61/63/65/66)",
  "    localparam integer NW = 70;  // = wrapper 的 SNAP_NW_P6E (构建 F, 2026-10-10; 原 61/63/65/66/67)", 1)
E("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "        chk(\"5a 末字 (0x20+4*(NW-1) = 0x128 @NW=67) 读得到\", v, code_of(NW-1));",
  "        chk(\"5a 末字 (0x20+4*(NW-1) = 0x134 @NW=70) 读得到\", v, code_of(NW-1));", 1)
E("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "        chk(\"6a 未实现地址 (0x20+4*NW = 0x12C @NW=67) 回 0\", v, 32'h0000_0000);",
  "        chk(\"6a 未实现地址 (0x20+4*NW = 0x138 @NW=70) 回 0\", v, 32'h0000_0000);", 1)
E("_proj_10g/notes/p7b_biz_win/run_tb_biz_win.bat",
  "findstr /C:\"SNAP_NW_P6E = 67\" \"%ROOT%\\board\\wrapper_p4.v\" >NUL || ( echo [FINGERPRINT FAIL] wrapper is not 67-word & exit /b 92 )",
  "findstr /C:\"SNAP_NW_P6E = 70\" \"%ROOT%\\board\\wrapper_p4.v\" >NUL || ( echo [FINGERPRINT FAIL] wrapper is not 70-word & exit /b 92 )", 1)
E("_proj_10g/notes/p7b_biz_win/run_tb_biz_win.bat",
  "REM 2026-10-10 (build E): fingerprint 66 -> 67.",
  "REM 2026-10-10 (build F): fingerprint 67 -> 70.\n"
  "REM 2026-10-10 (build E): fingerprint 66 -> 67.", 1)
E("_proj_10g/notes/p7b_biz_win/run_xvlog_wrapper.bat",
  "findstr /C:\"SNAP_NW_P6E = 67\" \"%SRCFILE%\" >NUL || ( echo [FINGERPRINT FAIL] source is not the 67-word version & exit /b 92 )",
  "findstr /C:\"SNAP_NW_P6E = 70\" \"%SRCFILE%\" >NUL || ( echo [FINGERPRINT FAIL] source is not the 70-word version & exit /b 92 )", 1)
E("sim/p5wu_p1p2/run_xvlog_wrapper63.bat",
  "findstr /C:\"SNAP_NW_P6E = 67\" \"%SRCFILE%\" >NUL || ( echo [FINGERPRINT FAIL] source is not the 67-word version & exit /b 92 )",
  "findstr /C:\"SNAP_NW_P6E = 70\" \"%SRCFILE%\" >NUL || ( echo [FINGERPRINT FAIL] source is not the 70-word version & exit /b 92 )", 1)

# ===========================================================================
# ⑦ 反例台架夹具几何 (negctrl_fix3.sh 的 gen_inputs.py; 它自带 GEOM_GUARD,
#    不同代会**响亮失败** ⇒ 必须同批改)
# ===========================================================================
E("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "  快照 : SNAP_BEGIN / TLATCH / GEN / MAGIC / BID / MARKER / W0..W66 / UNIMPL / SNAP_END\n"
  "         ⚠️ 几何 = **67 字 / BID 0x19** (P7b 构建 E, 2026-10-10 同步轮从 63 字/BID 0xA 同步)\n"
  "            ⛔ 2026-10-10 构建 E 同步: 上一行原写 \"几何 = 63 字 / BID 10 (P7b Stage C)\";",
  "  快照 : SNAP_BEGIN / TLATCH / GEN / MAGIC / BID / MARKER / W0..W69 / UNIMPL / SNAP_END\n"
  "         ⚠️ 几何 = **70 字 / BID 0x1A** (P7b 构建 F, 2026-10-10 同步轮从 67 字/BID 0x19 同步)\n"
  "            ⛔ 2026-10-10 构建 F 同步: 上一行原写 \"几何 = 67 字 / BID 0x19 (构建 E)\";\n"
  "            ⛔ 2026-10-10 构建 E 同步: 那一行的上一行原写 \"几何 = 63 字 / BID 10 (P7b Stage C)\";", 1)
E("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **67 字 / BID 0x19**, accept 默认也已是 67 字 / BID 0x19\n"
  "# (`_geo_guard` 守着)。本轮订正经过: 63 字/BID 0xA (Stage C) → 65 字/BID 0x17 (构建 C) →\n"
  "# 66 字/0x18 (构建 D) → **67 字/0x19 (构建 E, 未实现地址 0x12C)**; 中间两轮几何同步都漏了本夹具。\n"
  "NW_FIX = 67                # 快照字数 (W0..W66)\n"
  "BID_FIX = 0x00000019       # 位流身份 (P7b 构建 E) —— ⛔ 2026-10-10: 原值 0x0000000A (P7b Stage C)",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **70 字 / BID 0x1A**, accept 默认也已是 70 字 / BID 0x1A\n"
  "# (`_geo_guard` 守着)。本轮订正经过: 63 字/BID 0xA (Stage C) → 65 字/BID 0x17 (构建 C) →\n"
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → **70 字/0x1A (构建 F, 未实现地址 0x138)**。\n"
  "NW_FIX = 70                # 快照字数 (W0..W69)\n"
  "BID_FIX = 0x0000001A       # 位流身份 (P7b 构建 F) —— ⛔ 2026-10-10: 原值 0x00000019 (构建 E)", 1)
E("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "    \"\"\"**67 字 (W0..W66)**; lat = 该块锁存的时刻 (秒) ⇒ 三个域自由计数由它算出。",
  "    \"\"\"**70 字 (W0..W69)**; lat = 该块锁存的时刻 (秒) ⇒ 三个域自由计数由它算出。", 1)

# ===========================================================================
# ⑧ A3 负对照轮的板侧臂脚本 (上一轮的件; 几何/身份同批跟上, 免得留下"半代"脚本)
# ===========================================================================
E("_proj_10g/notes/p7b_a3_negctl_20261010/burn_arm.sh",
  "     BID=0x00000019; BIE=0x00000019; NW=67 ;;   # 构建 E: 67 字 (新增 W66 = tcp_tx_frame.stat_winstall)",
  "     BID=0x0000001A; BIE=0x0000001A; NW=70 ;;   # 构建 F: 70 字 (新增 W67/W68/W69 = 三个纯观测仪器)", 1)
E("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
  "#     (i)  缺省档 (NW=67 / 0x12C / BID 0x19) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);",
  "#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1A) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);", 1)
E("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
  'echo "### C-a) 默认档 (NW=67 / 0x12C / BID 0x19) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x19)"',
  'echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1A) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1A)"', 1)


# ===========================================================================
# ⑨ 【2026-10-10 读侧加固轮】给"同步"这件事装牙 —— 三条结构性断言
#
#   动机 (同一类事故第三次): 每次扩窗都要把仓内外**所有**读侧件同步, 而"同步"以前
#   只靠一份**手写清单** + "锚点命中数"。已连翻三轮车:
#     · 66 字轮 (构建 D) 漏 `_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py`;
#     · 67 字轮 (构建 E) 又漏同一个文件;
#     · 70 字轮 (构建 F) 独立审查在两个方向各抓到一处 ——
#       ① `_proj_pcie/p6e_snap_check.sh` 的 `WLABEL` 表**只到 W64** (65 项), 而循环按
#          `SNAP_WORDS`(=70) 走 ⇒ W65..W69 打印 `<无标签>` (缺口从构建 D 起, 三轮未补);
#       ② 搜索面里 BID 那一组只含 `EXPECT_BID=\${` ⇒ **看不见 `BID_EXPECT=`/`BIE=`/`BID_FIX=`
#          这个命名族** (实例: `p7b_longflow_board/lf_dl.sh:28` · `p7b_window_side_20261010/
#          wrun.sh:19` · `wdump_probe.sh:21`), 而"读绝对地址的调用实参"(`axil_read(32'hXXX)` /
#          `rd 0x1XX`) 那一族也从未进过搜索面。
#   根因 = 旧脚本**只断言"锚点命中数"、不断言"表长 == NW"**。下面三条把它封死:
#     A. 表长断言   : 每张名字表/字表的**项数 == NW** (NW **现读**权威源, 不写死);
#     B. 搜索面全扫 : 三个命名族全仓扫; 每个命中文件必须**已登记** (EDITS 目标 或 ALLOW 分类)
#                     ⇒ "新文件命中却没人分类"变成硬失败, 而不是"没人看见";
#     C. 默认值一致 : 每个读侧默认值 (NW / BID / 未实现地址) == 权威源现读值。
#   ⚠️ 判据必须**走到退出码** (全局 #53 哑门族: "打了 FAIL 却 exit 0"): 任一条红 ⇒
#      `APPLY_READSIDE` 末行 FAIL + return 1。
#   ⚠️ 负对照 (证明判据有牙) 一律在**临时副本**上做 (`--negctl=<名>` 分支); 本脚本
#      **绝不**为了演示而改仓内文件。
# ===========================================================================
import re
import shutil
import subprocess
import tempfile


def _src(rel, overlay=None):
    """读一件。`overlay` = {rel: 文本} 时**优先**取 overlay 里的内容 —— 这是负对照
    唯一的注入口 (内容来自 tempfile 里的故意破坏副本, 仓内文件一个字节都不动)。"""
    if overlay and rel in overlay:
        return overlay[rel]
    p = os.path.join(REPO, rel.replace("/", os.sep))
    return io.open(p, "r", encoding="utf-8", errors="replace").read()


def authoritative(overlay=None):
    """**权威源** = `board/wrapper_p4.v` (RTL 是唯一真源: 读侧一切几何/身份由它派生)。
    ⚠️ 这个源**本身会漂**(它按设计逐代变: 61→63→65→66→67→70 / BID 8→9→A→17→18→19→1A),
    所以断言不许写死期望值 —— 一律**现读**再比。"""
    s = _src("board/wrapper_p4.v", overlay)
    nw = int(re.search(r"localparam\s+SNAP_NW_P6E\s*=\s*(\d+)\s*;", s).group(1))
    bid = "0x%08X" % int(re.search(r"\.BUILD_ID_V\s*\(\s*32'h([0-9A-Fa-f]+)\s*\)", s).group(1), 16)
    return nw, bid


def unimpl_addr(nw):
    return 0x20 + 4 * nw


def _arr_body(s, anchor):
    """取 `anchor` 之后、配平到 depth 0 的括号体 (双引号内的括号不计数)。
    anchor 末字符 = `(` 时按圆括号配平; = `[` 时按方括号配平 (python 字面表)。"""
    i = s.index(anchor) + len(anchor)
    op, cl = ("[", "]") if anchor.rstrip().endswith("[") else ("(", ")")
    depth, q, j = 1, False, i
    while j < len(s):
        c = s[j]
        if q:
            q = (c != '"')
        elif c == '"':
            q = True
        elif c == op:
            depth += 1
        elif c == cl:
            depth -= 1
            if depth == 0:
                return s[i:j]
        j += 1
    raise ValueError("括号未配平: " + anchor)


# ---- A. 表长断言: 种类 (a) bash 数组(引号项) (b) bash 关联数组(显式数字键) (c) python 字面表
TABLE_SPECS = [
    # (文件, 种类, 锚点, 说明)                                    —— 每条的期望长度都 = NW
    ("_proj_pcie/p6e_snap_check.sh", "bash_quoted", "WLABEL=(",
     "WLABEL (逐字打印的名字表; 缺一项 ⇒ 该字打成 <无标签>)"),
    ("_proj_pcie/p7b_biz/p7b_snap.sh", "bash_keys", "declare -A NAME=(",
     "NAME[] (板侧取数器的名字表)"),
    ("_proj_pcie/p7b_gate4_livefake.sh", "py_list", "W = [",
     "假对端的 W 字表 (长度 < NW ⇒ for i in range(nw) 直接 IndexError = '整台安静')"),
    ("_proj_pcie/p7b_gate4_negctrl.sh", "bash_plain", "local -a V=(",
     "合成夹具的 V 字表 (长度 < NW ⇒ 尾部字打 0 = 假数据)"),
    #   `{nw}` = 现读的权威 NW (anchor 由它拼出来 —— 分档脚本的"现役那一档"必须 = 现役几何)
    ("_proj_pcie/p7b_gate4_selftest.sh", "bash_addrs",
     "if [ \"$SW\" -ge {nw} ]; then",
     "假板子的 FAKE_TAIL 地址表 (地址条数必须 == NW-60=W60..W(NW-1), 末条 = 未实现地址)"),
]


def table_count(rel, kind, anchor, overlay=None, nw=None):
    s = _src(rel, overlay)
    anchor = anchor.replace("{nw}", str(nw)) if nw else anchor
    if kind == "bash_addrs":
        # FAKE_TAIL: 分档分支体的 `0X<hex>)` 地址条 (条数 == NW-60; 末条 == 未实现地址)
        i = s.index(anchor)
        seg = s[i:i + 4000].split("elif")[0]
        return [int(x, 16) for x in re.findall(r"0X([0-9A-Fa-f]+)\)", seg)]
    if kind == "py_list":
        # `W = [..] + [..] * k + [..]` (跨行 + 行尾注释) —— 从 `W = [` 那一行起,
        # 取到第一条**整行注释**为止 (行内 `#` 之后也去掉), 再把函数调用/裸名换成 0 求长度。
        # ⚠️ 不能用 `_arr_body` 的方括号配平: 表达式里每一段 `[..]` 自己就是配平的
        #    (实测会把第一段 `[100, ... ]` 当整体 ⇒ 长度报 8 而不是 70)。
        lines = s.split("\n")
        i = [k for k, l in enumerate(lines) if l.strip().startswith(anchor)][0]
        buf = []
        for l in lines[i:]:
            if l.strip().startswith("#"):
                break
            buf.append(re.sub(r"#.*$", "", l).replace("\\", "").strip())
        expr = " ".join(buf)
        expr = expr[expr.index("["):]
        expr = re.sub(r"[A-Za-z_]\w*\s*\([^()]*\)", "0", expr)
        expr = re.sub(r"\b[A-Za-z_]\w*\b", "0", expr)
        return len(eval(expr, {"__builtins__": {}}, {}))   # noqa: S307 (可信仓内文件)
    body = _arr_body(s, anchor)
    if kind == "bash_quoted":
        n = body.count('"')
        if n % 2:
            raise ValueError("%s: 引号数 %d 为奇数 (数组体被截断?)" % (rel, n))
        return n // 2
    if kind == "bash_plain":
        body = re.sub(r"(?m)^\s*#.*$", "", body)      # 去**整行**注释 (行内注释不动, 免得误伤数据)
        return len(body.split())
    if kind == "bash_keys":
        # ⚠️ 必须先去掉**整行注释**再数键: p7b_snap.sh 的注释里逐字引用了 `[56]=`/`[33]=`/`[34]=`
        #    (讲"以前那个紧贴写法/重复键的坑") ⇒ 不去注释会多数出 5 个键 (实测 75 vs 70)。
        body = re.sub(r"(?m)^\s*#.*$", "", body)
        ks = sorted(int(x) for x in re.findall(r"\[(\d+)\]=", body))
        # 键必须是 {0..NW-1} 且无洞无重: 返回键列表供上层判
        return ks
    raise ValueError("未知表种类 " + kind)


# ---- C. 默认值一致性: 每个读侧默认值都必须 == 权威源现读值
#      kind: NW / BID / UNIMPL (regex 必须恰好一个捕获组)
DEFAULT_SPECS = [
    ("_proj_pcie/p6e_snap_check.sh", r"SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)\}", "NW"),
    ("_proj_pcie/p6e_snap_check.sh", r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_pcie/p7b_biz/p7b_snap.sh", r"NW=\$\{NW:-(\d+)\}", "NW"),
    ("_proj_pcie/p7b_biz/p7b_snap.sh", r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_pcie/p7b_gate4_accept.sh", r"SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)\}", "NW"),
    ("_proj_pcie/p7b_gate4_accept.sh", r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_pcie/p7b_gate4_selftest.sh", r"SW=\$\{SNAP_WORDS:-(\d+)\}", "NW"),
    ("_proj_pcie/p7b_gate4_selftest.sh",
     r"FAKE_BID:-?(0x[0-9A-Fa-f]+)", "BID"),
    ("_proj_pcie/p6e_snap_selftest_fix2.sh", r"FAKE_BID:-?(0x[0-9A-Fa-f]+)", "BID"),
    ("_proj_pcie/p7b_gate4_negctrl.sh", r"echo \"BID (0x[0-9A-Fa-f]+)\"", "BID"),
    ("_proj_pcie/p7b_gate4_negctrl.sh", r"for \(\( i = 0; i < (\d+); i\+\+ \)\)", "NW"),
    ("_proj_pcie/p7b_gate4_negctrl.sh", r"awk -v NW=(\d+)", "NW"),
    ("_proj_pcie/p7b_gate4_livefake.sh",
     r'bid = \{(\d+): "0x[0-9A-Fa-f]+"', "NW_key"),          # 表里有**现役 NW** 这一档
    ("_proj_pcie/p7b_gate4_livefake.sh",
     r'\}\.get\(nw, "(0x[0-9A-Fa-f]+)"\)', "BID"),           # 兜底值 = 现役 BID
    ("_proj_10g/notes/p7b_gate4_3/final_state.sh", r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_10g/notes/p7b_gate4_3/final_state.sh", r"UNIMPL=\$\(rd (0x[0-9A-Fa-f]+)\)", "UNIMPL"),
    ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh", r"(?m)^NW=\$\{NW:-(\d+)\}", "NW"),
    ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh", r"(?m)^EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh", r"(?m)^NW=\$\{NW:-(\d+)\}", "NW"),
    ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh", r"(?m)^EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py", r"NW_FIX = (\d+)", "NW"),
    ("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py", r"BID_FIX = (0x[0-9A-Fa-f]+)", "BID"),
    ("_proj_10g/notes/p7b_biz_win/tb_biz_win.v", r"localparam integer NW = (\d+)", "NW"),
    # 单元门: 地址/期望值都锚在**活的那一行** (`^\s*u_dut...` 排掉 `//` 注释里的历史句)
    ("sim/p6e_pcie/tb_p6e_pcie_counters.v",
     r"(?m)^\s*u_dut\.u_pcie_xdma\.axil_read\(32'h04, v\); chk\(\"0b BUILD_ID[^\"]*\", v, 32'h([0-9A-Fa-f]+)\);", "BID"),
    ("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
     r"(?m)^\s*u_dut\.u_pcie_xdma\.axil_read\(32'h04, v\); chk\(\"2  BUILD_ID[^\"]*\", v, 32'h([0-9A-Fa-f]+)\);", "BID"),
    ("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
     r"axil_read\(32'h([0-9A-Fa-f]+), v\);\n\s*chk\(\"9  未实现地址", "UNIMPL"),
    ("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
     r"(?m)^\s*chk\(\"9  未实现地址 (0x[0-9A-Fa-f]+)", "UNIMPL"),
    ("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
     r"axil_read\(32'h([0-9A-Fa-f]+), v\);\n\s*chk\(\"7b 0x", "UNIMPL"),
    ("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
     r"(?m)^\s*chk\(\"7b (0x[0-9A-Fa-f]+) reads 0 no wrap", "UNIMPL"),
    ("_proj_10g/notes/p7b_biz_win/run_tb_biz_win.bat", r"findstr /C:\"SNAP_NW_P6E = (\d+)\"", "NW"),
    ("_proj_10g/notes/p7b_biz_win/run_xvlog_wrapper.bat", r"findstr /C:\"SNAP_NW_P6E = (\d+)\"", "NW"),
    ("sim/p5wu_p1p2/run_xvlog_wrapper63.bat", r"findstr /C:\"SNAP_NW_P6E = (\d+)\"", "NW"),
    # 现役板级轮的跑臂 (免"半代"脚本; 与各轮 *board_* 目录里的历史快照区分开)
    ("_proj_10g/notes/p7b_buildF_board_20261010/run_arm.sh", r"BIE=(0x[0-9A-Fa-f]+); NW=(\d+)", "BID_NW_PAIR"),
    ("_proj_10g/notes/p7b_buildF_board_20261010/burn_arm.sh", r"BIE=(0x[0-9A-Fa-f]+); NW=(\d+)", "BID_NW_PAIR"),
]

# 派生式 (判据 = 一个必须成立的算式, 而不是单点值): check_window.py 的新字数分解
DERIVED_SPECS = [
    ("_proj_10g/notes/p7b_biz_win/check_window.py",
     [("nnew_top", r"nnew_top = (\d+)"), ("ntx", r"ntx = (\d+)"), ("nnew", r"nnew = (\d+)")],
     lambda v, nw: v["nnew_top"] + v["ntx"] + v["nnew"] == nw - 51,
     "nnew_top + ntx + nnew == NW - 51 (W51..W(NW-1) 的分解; 70-51=19)"),
]

# ---- B. 搜索面全扫: 三个命名族。**每个命中文件都必须已登记**, 否则 FAIL。
FAMILIES = [
    ("geometry-NW", re.compile(
        r"NW=\$\{NW:-(\d+)|SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)|SW=\$\{SNAP_WORDS:-(\d+)"
        r"|NW_FIX\s*=\s*(\d+)|awk -v NW=(\d+)|localparam\s+integer NW = (\d+)"
        r"|nnew_top = (\d+)|(?<![\w.])NW=(\d+)(?=[\s;)\"'&|]|$)")),   # ⚠️ 末项 = **裸字面形式**
        #   (`NW=67` / `NW=70` —— 例如 `wrun.sh:19 BIE=0x00000019; NW=67` /
        #    `wdump_probe.sh:21 … NW=67 BID_EXPECT=0x00000019 …`);
        #   只写 `${NW:-}` 那一族会**看不见它** (2026-10-10 实测: wdump_probe.sh 漏网)。
        #   ⚠️ 末项带 ASCII 边界前瞻 —— 中文/全角紧跟其后时不算 (否则散文 "实测 NW=1，" 会假命中)。
    ("identity-BID", re.compile(
        r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)"
        r"|BID_EXPECT=\$\{BID_EXPECT:-(0x[0-9A-Fa-f]+)"
        r"|BID_EXPECT=(0x[0-9A-Fa-f]+)"                 # ⚠️ 裸字面形式 (wdump_probe.sh:21)
        r"|BID_FIX = (0x[0-9A-Fa-f]+)|BIE=(0x[0-9A-Fa-f]+)"
        r"|FAKE_BID:-?(0x[0-9A-Fa-f]+)|BUILD_ID_V\s*\(\s*32'h([0-9A-Fa-f]+)")),
    ("unimpl-addr", re.compile(
        r"axil_read\(32'h([0-9A-Fa-f]+)|UNIMPL_ADDR=\$\{UNIMPL_ADDR:-"
        r"|UNIMPL=\$\(rd (0x1[0-9A-Fa-f]{2})\)|rd (0x1[0-9A-Fa-f]{2})")),
]

# 允许清单: (路径正则, 分类) —— **分类只有三档** + 三类"非读侧"豁免 (逐条给理由)。
ALLOW = [
    # —— 权威源 (只读; 它是"现读值"的来处, 不是"要同步的默认值") ——
    (r"^board/wrapper_p4\.v$", "权威源: SNAP_NW_P6E / BUILD_ID_V (只读; 由 ⑨ 现读)"),
    # —— 现役 (已同步/本脚本正在改) ——
    (r"^_proj_10g/notes/p7b_buildF_board_20261010/", "现役: 构建 F 板级轮 (在飞)"),
    (r"^_proj_10g/notes/p7b_buildF/", "现役: 本构建的 apply_* 脚本 (old-side 字符串是**补丁左值**, 必须留旧值)"),
    (r"^_proj_10g/notes/p7b_biz_win/(check_window\.py|tb_biz_win\.v|run_tb_biz_win\.bat|run_xvlog_wrapper\.bat)$",
     "现役: 窗口几何守卫 (F 已同步; 其 nnew_top 由 ⑨-C 派生式断言)"),
    # —— 旧位流读法 (可留: 值刻意绑某代已归档位流, 改它反而毁掉那一代的取证) ——
    (r"^_proj_10g/notes/p7b_(a3_negctl|a7_board|buildE_board|gap9_tx_board|"
     r"lonsend_board|udp_longrun|uplink_ceil|window_side)_2026\d+/", "旧位流读法: 各轮板级现场快照/跑臂"),
    (r"^_proj_10g/notes/p7b_longflow_board/", "旧位流读法: 长流台架母版 (默认 = S3 档; 各轮一律用 env 覆盖 NW/BID_EXPECT)"),
    (r"^_proj_10g/notes/p7b_(bench|board_stagea|board_stagec|wu_w54|wu_loop|wu_harness_fix|biz_s1|biz_tcpreg|biz_win/neg)/",
     "旧位流读法: 历史轮件/负面夹具"),
    (r"^_proj_10g/notes/p7b_biz_win/apply_.*\.py$",
     "历史注释: 更早的 apply 脚本 (old/new 两侧都是那代的值, 是补丁左值)"),
    (r"^_proj_10g/notes/p7b_p5wrapper_diag_20261010/",
     "另一路 agent 的 p5wrapper 对拍副本 (在本加固轮的范围外; 只登记不动)"),
    (r"^_proj_10g/notes/p7b_buildE/", "旧位流读法: 上一代 apply_* (old/new 两侧都是那代的值)"),
    (r"^_proj_10g/notes/p7b_a7/", "旧位流读法: 构建 C/D 的 apply_*"),
    (r"^_proj_10g/notes/p7b_gate4_tools/", "旧位流读法: 门工具轮的历史副本/生成物"),
    (r"^_proj_10g/notes/p7b_(rate|ratefrm|chain_cov)/", "同名不同物/变异件: 自带 NW 参数的自洽门 (NW=184 是帧字数)"),
    (r"^sim/p4gates/", "刻意的外来夹具 (禁全局替换)"),
    (r"^sim/snapcdc/|^tb/tb_snap_cdc\.v$",
     "同名不同物: `snap_cdc` 单元门的 NW 轴 = 束宽 (14/22) / 历史窗口宽 (24/32/36), 与现役字数无关"),
    (r"^sim/(p5bfix|p5b_|p5c_|p5d_|p5e_|p5sim|p5close|rxsim|txsim|p3sim)/", "sim 历史镜像件 (禁全局替换)"),
    (r"^sim/p5wu_p1p2/", "旧位流读法: 63 字世代的门与 run 器"),
    (r"^sim/p6e_pcie/", "旧代单元门 (参数自洽; 与 EDITS 里的 tb 共处, 由 EDITS 覆盖现役两件)"),
    (r"^_proj_pcie/(tb|rtl)/", "旧代单元门/最小实验设计 (自带 SNAP_NW 参数)"),
    (r"^tb/tb_snap63\.v$", "旧位流读法: 63 字世代门 (NW=63 是它的判据本体)"),
    (r"^int_scratch/", "scratch 目录 (非交付件)"),
    (r"^p6b_accept_final/", "历史读数目录 (36 字世代)"),
    (r"^_proj_10g/p7b_chain/", "旧代链门 (现役两件由 EDITS 覆盖)"),
    (r"^audit_scratch/", "审计 scratch"),
]


def _fileset(extra=None):
    """非忽略文件集 = git ls-files + git ls-files --others --exclude-standard。
    ⚠️ `.gitignore` 的目录规则会让 `grep -r` 与 `git ls-files` 给出**不同**集合 ⇒
    两边都要跑 (本函数就是"两边都跑"的代码化)。`extra` = 负对照用的虚拟新文件。"""
    out = []
    for cmd in ("git ls-files", "git ls-files --others --exclude-standard"):
        r = subprocess.run(cmd.split(), cwd=REPO, stdout=subprocess.PIPE)
        out += r.stdout.decode("utf-8", "replace").splitlines()
    return sorted(set(out) | set(extra or []))


def assert_tables(nw, overlay=None):
    fails = []
    for rel, kind, anchor, note in TABLE_SPECS:
        try:
            got = table_count(rel, kind, anchor, overlay, nw)
        except Exception as e:                                       # noqa: BLE001
            print("FAIL %-58s 表长断言异常: %s" % (rel, e))
            fails.append(rel)
            continue
        if kind == "bash_addrs":
            # 覆盖 = W61..W(NW-1) 的字地址 **+ 未实现地址那一格** ⇒ 共 NW-60 条, 末条 = 0x20+4*NW
            want = list(range(0x20 + 4 * 61, 0x20 + 4 * (nw + 1), 4))
            ok = got == want
            print("%s %-58s 地址条数 = %d / 期望 %d (末条 0x%X)   %s"
                  % ("OK  " if ok else "FAIL", rel, len(got), len(want),
                     got[-1] if got else 0, note))
            if not ok:
                fails.append(rel)
            continue
        if kind == "bash_keys":
            want = list(range(nw))
            ok = got == want
            print("%s %-58s 键集合 = {%d..%d} 共 %d 项 / 期望 {%d..%d} 共 %d 项   %s"
                  % ("OK  " if ok else "FAIL", rel, got[0] if got else -1, got[-1] if got else -1,
                     len(got), 0, nw - 1, nw, note))
        else:
            ok = got == nw
            print("%s %-58s 表长 = %d / 期望 NW = %d   %s"
                  % ("OK  " if ok else "FAIL", rel, got, nw, note))
        if not ok:
            fails.append(rel)
    return fails


def assert_defaults(nw, bid, overlay=None):
    want = {"NW": nw, "BID": int(bid, 16), "UNIMPL": unimpl_addr(nw)}
    fails = []
    for rel, rx, kind in DEFAULT_SPECS:
        s = _src(rel, overlay)
        ms = re.findall(rx, s)
        if kind == "BID_NW_PAIR":
            got = [(int(a, 16), int(b)) for a, b in ms]
            ok = bool(got) and all(v == (want["BID"], nw) for v in got)
            shown = " / ".join("0x%08X,NW=%d" % v for v in got) or "(0 命中)"
        elif kind == "NW_key":
            got = [int(x) for x in ms]
            ok = bool(got) and (nw in got) and all(v == nw for v in got)
            shown = ",".join(ms) or "(0 命中)"
        else:
            vals = [int(m, 16) if kind in ("BID", "UNIMPL") else int(m) for m in ms]
            ok = len(vals) == 1 and vals[0] == want[kind]
            shown = ",".join(ms) or "(0 命中)"
        wshow = {"BID": "0x%08X" % want["BID"], "NW_key": "含 %d 档" % nw,
                 "NW": str(want["NW"]), "UNIMPL": "0x%X" % want["UNIMPL"],
                 "BID_NW_PAIR": "0x%08X,NW=%d" % (want["BID"], nw)}[kind]
        print("%s %-52s %-14s = %-22s 期望 %s   %s"
              % ("OK  " if ok else "FAIL", rel, kind, shown, wshow, rx[:30]))
        if not ok:
            fails.append("%s[%s]" % (rel, kind))
    for rel, names, pred, note in DERIVED_SPECS:
        s = _src(rel, overlay)
        v = {}
        for nm, rx in names:
            m = re.search(rx, s)
            v[nm] = int(m.group(1)) if m else -1
        ok = pred(v, nw)
        print("%s %-52s 派生式             %s   %s"
              % ("OK  " if ok else "FAIL", rel, v, note))
        if not ok:
            fails.append("%s[derived]" % rel)
    return fails


COMMENT_PREFIX = ("//", "#", "REM", "rem", "*", "--", "%")
#   ⚠️ 扫之前先去掉**整行注释** (每种语言的注释前缀都列上): 注释里的旧值属"历史注释（可留）"，
#      让它们进"未登记"清单只会制造噪声 (实测: `tb_snap_cdc.v` 的 `// NW=32 时…` /
#      `run_tb_snap_cdc.bat` 的 `REM NW=36` 一族)。**行内注释不剥** (那会误伤数据行)。


def _strip_comment_lines(text):
    out = []
    for l in text.split("\n"):
        if l.lstrip().startswith(COMMENT_PREFIX):
            out.append("")
        else:
            out.append(l)
    return "\n".join(out)


def assert_search_face(overlay=None, extra=None):
    """搜索面全扫: 每个命中文件必须已登记 (EDITS 目标 或 ALLOW 分类)。"""
    targets = set(rel for rel, _a, _b, _c in EDITS)
    ext = (".sh", ".bat", ".py", ".v", ".vh", ".tcl", ".ps1", ".cmd")
    fails, n_hit = [], 0
    for fam, rx in FAMILIES:
        hit = []
        for rel in _fileset(extra):
            if not rel.endswith(ext):
                continue
            if overlay and rel in overlay:
                text = overlay[rel]
                if rx.search(_strip_comment_lines(text)):
                    hit.append(rel)
                continue
            p = os.path.join(REPO, rel.replace("/", os.sep))
            try:
                b = open(p, "rb").read()
            except OSError:
                continue
            if b"\x00" in b[:4096] or len(b) > 4 * 1024 * 1024:
                continue
            if rx.search(_strip_comment_lines(b.decode("utf-8", "replace"))):
                hit.append(rel)
        n_hit += len(hit)
        unreg = []
        for rel in hit:
            if rel in targets:
                continue
            if any(re.search(pat, rel) for pat, _cls in ALLOW):
                continue
            unreg.append(rel)
        print("---- 搜索面 [%s]: 命中 %d 文件 (已登记 %d / 未登记 %d)"
              % (fam, len(hit), len(hit) - len(unreg), len(unreg)))
        for rel in unreg:
            print("FAIL 未登记的命中: %-60s ⇒ 先分类 (三档) 再决定改不改" % rel)
            fails.append("%s:%s" % (fam, rel))
    print("SEARCH_FACE %s (%d 族 / %d 命中文件)" % ("OK" if not fails else "FAIL", len(FAMILIES), n_hit))
    return fails


def list_face():
    """`--face`: 把三个族的**每个命中文件 + 分类**打出来 (这就是"任务 1 全表"的脚本面;
    .md 文档不在扫的面内 —— 它们的分类恒为"历史注释（可留）", 由 REPORT.md 的文档节承担)。"""
    targets = set(rel for rel, _a, _b, _c in EDITS)
    ext = (".sh", ".bat", ".py", ".v", ".vh", ".tcl", ".ps1", ".cmd")
    rows = []
    for fam, rx in FAMILIES:
        for rel in _fileset():
            if not rel.endswith(ext):
                continue
            p = os.path.join(REPO, rel.replace("/", os.sep))
            try:
                b = open(p, "rb").read()
            except OSError:
                continue
            if b"\x00" in b[:4096] or len(b) > 4 * 1024 * 1024:
                continue
            if not rx.search(_strip_comment_lines(b.decode("utf-8", "replace"))):
                continue
            cls = "EDITS 目标 (现役/已同步)" if rel in targets else None
            if cls is None:
                for pat, c in ALLOW:
                    if re.search(pat, rel):
                        cls = c
                        break
            rows.append((fam, rel, cls or "**未登记**"))
    for fam, rel, cls in rows:
        print("%-13s | %-74s | %s" % (fam, rel, cls))
    print("--face 共 %d 行 (%d 文件)" % (len(rows), len(set(r[1] for r in rows))))
    return 0


def negctl(name):
    """负对照 (判据要有牙): 在 **tempfile 里的故意破坏副本**上重跑**同一套**断言函数
    (同一条代码路径), 必须看到 FAIL。
    ⛔ 仓内文件一个字节都不动 —— 破坏件写在 `tempfile.mkdtemp()` 里, 靠 `overlay` 注入。
    RC 约定: **0 = 负对照成立 (断言确实变红)** / **1 = 负对照失败 (断言没牙)** / 2 = 未知档。"""
    nw, bid = authoritative()
    tmp = tempfile.mkdtemp(prefix="readside_negctl_")
    try:
        overlay, extra, title = {}, [], ""
        if name == "table":      # ① 表长断言: 把 WLABEL 截短一项
            src = "_proj_pcie/p6e_snap_check.sh"
            s = _src(src)
            cut = ' "tx_win_at_winstall (tcp_tx_frame.o_win_at_winstall: 等窗拍锁存; 构建 F)" )'
            bad = s.replace(cut, " )", 1)
            assert bad != s, "负对照 table: 锚点没命中 (要删的那一行漂了?)"
            title = "把 %s 的 WLABEL 末项删掉 (表长 %d → %d)" % (src, nw, nw - 1)
            overlay = {src: bad}
            p = os.path.join(tmp, "p6e_snap_check.sh")
            io.open(p, "w", encoding="utf-8", newline="").write(bad)
            print("NEGCTL 破坏件 (临时副本, 仓内原件不动): %s" % p)
            print("NEGCTL 做法: %s" % title)
            fails = assert_tables(nw, overlay)
        elif name == "bid":      # ② 默认值断言: 把某个 EXPECT_BID 改回旧代
            src = "_proj_10g/notes/p7b_affinity/j6_r6fix.sh"
            s = _src(src)
            bad = s.replace("EXPECT_BID=${EXPECT_BID:-%s}" % bid,
                            "EXPECT_BID=${EXPECT_BID:-0x00000009}", 1)
            assert bad != s, "负对照 bid: 锚点没命中"
            title = "把 %s 的 EXPECT_BID 从现役 %s 改成旧代 0x00000009" % (src, bid)
            overlay = {src: bad}
            p = os.path.join(tmp, "j6_r6fix.sh")
            io.open(p, "w", encoding="utf-8", newline="").write(bad)
            print("NEGCTL 破坏件 (临时副本, 仓内原件不动): %s" % p)
            print("NEGCTL 做法: %s" % title)
            fails = assert_defaults(nw, bid, overlay)
        elif name == "face":     # ③ 搜索面: 一个"下一轮的新文件"带 BID_EXPECT 出现在未登记路径
            src = "_proj_10g/notes/p7b_newround_2099/new_runner.sh"
            body = "#!/bin/bash\nBID_EXPECT=${BID_EXPECT:-%s}\nNW=${NW:-%d}\n" % ("0x00000019", 70)
            extra = [src]
            overlay = {src: body}
            p = os.path.join(tmp, "new_runner.sh")
            io.open(p, "w", encoding="utf-8", newline="").write(body)
            print("NEGCTL 破坏件 (临时副本, 仓内原件不动): %s" % p)
            print("NEGCTL 做法: 造一个**未登记路径**的新文件 %s (带 BID_EXPECT=0x00000019 / NW=70)" % src)
            fails = assert_search_face(overlay, extra)
        elif name == "oldkey":   # ④ 罪证复现: 旧搜索键看不见 BID_EXPECT 族
            old_rx = re.compile(r"EXPECT_BID=\$\{")
            new_rx = FAMILIES[1][1]
            for src in ("_proj_10g/notes/p7b_longflow_board/lf_dl.sh",
                        "_proj_10g/notes/p7b_window_side_20261010/wrun.sh",
                        "_proj_10g/notes/p7b_window_side_20261010/wdump_probe.sh"):
                s = _src(src)
                print("NEGCTL oldkey %-62s 旧键命中=%d 新族命中=%d"
                      % (src, len(old_rx.findall(s)), len(new_rx.findall(s))))
            ok = all(len(new_rx.findall(_src(x))) > 0 and len(old_rx.findall(_src(x))) == 0
                     for x in ("_proj_10g/notes/p7b_longflow_board/lf_dl.sh",
                               "_proj_10g/notes/p7b_window_side_20261010/wrun.sh",
                               "_proj_10g/notes/p7b_window_side_20261010/wdump_probe.sh"))
            teeth = ok
            detail = "三个实例全是 旧键=0 / 新族≥1 ⇒ 旧搜索面确实瞎"
        else:
            print("NEGCTL 未知名: %s" % name)
            return 2
        if name != "oldkey":
            teeth = bool(fails)
            detail = ("断言确实变红 (共 %d 条 FAIL)" % len(fails)) if teeth else "断言没红"
        print("NEGCTL_VERDICT %s (%s) ⇒ %s"
              % ("有牙" if teeth else "没牙", detail,
                 "真实运行会 FAIL 并非零退出" if teeth else "这条断言在真仓里永远绿!"))
        # ⚠️ 退出码与**真实运行同语义**: 断言红 ⇒ 1 (这就是"判据走到退出码"的实测 RC);
        #    断言没红 ⇒ 0 (负对照失败, 得去修断言)。
        print("NEGCTL_EXIT=%d" % (1 if teeth else 0))
        return 1 if teeth else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    check = "--check" in sys.argv[1:]
    only_assert = "--assert" in sys.argv[1:]      # 只跑 ⑨ 三条断言 (不同步, 用于"扩了搜索面重跑")
    neg = [a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--negctl=")]
    if neg:
        return negctl("=".join(neg))
    if "--face" in sys.argv[1:]:
        return list_face()
    fails = []
    for rel, old, new, n in ([] if only_assert else EDITS):
        p = os.path.join(REPO, rel.replace("/", os.sep))
        b, nl = rd(p)
        old2 = old.replace("\n", nl.decode())
        new2 = new.replace("\n", nl.decode())
        s = b.decode("utf-8")
        k = s.count(old2)
        tag = "OK  " if k == n else "FAIL"
        print("%s %-56s hits=%d/%d  %s" % (tag, rel, k, n, old.split("\n")[0].strip()[:40]))
        if k != n:
            fails.append((rel, k, n, old.split("\n")[0][:80]))
            continue
        if not check:
            io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old2, new2))
    # ---- ⑨ 三条结构性断言 (每次都跑; 任一条红 ⇒ 退出码 != 0) ----
    nw, bid = authoritative()
    print("")
    print("AUTHORITY board/wrapper_p4.v: SNAP_NW_P6E = %d / BUILD_ID_V = %s / 未实现地址 = 0x%X"
          % (nw, bid, unimpl_addr(nw)))
    print("---- A. 表长断言 (每张表的项数必须 == NW) ----")
    fails += assert_tables(nw)
    print("---- B. 搜索面全扫 (三个命名族; 未登记即红) ----")
    fails += assert_search_face()
    print("---- C. 默认值一致性 (读侧默认值 == 权威源现读值) ----")
    fails += assert_defaults(nw, bid)
    print("APPLY_READSIDE %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
