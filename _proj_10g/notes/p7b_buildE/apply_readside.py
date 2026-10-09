#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 构建 E —— **读侧全部默认值同步** 66 字/BID 0x18 → 67 字/BID 0x19
   + 未实现地址 0x128 → 0x12C + `GEOM_TIERS` 加一行 + 取数器 `NAME[]` 补到新末字。
   显式清单 (每条断言命中数; 不做任何通配替换); 行尾用文件自身的风格。
   形状照 _proj_10g/notes/p7b_a7/apply_edges.py (+apply_negctrl.py)。
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
# ① 两个 j6 台架脚本: NW / EXPECT_BID / GEOM_TIERS
# ===========================================================================
for f in ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
          "_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh"):
    E(f, "NW=${NW:-66}", "NW=${NW:-67}", 1)
    E(f,
      '"66|0x00000018|61 62|构建 D (2026-10-10) 66 字 / BID 0x18 (P7B-A7: W65 = mac_tx_10g.stat_tx_idle)"',
      '"67|0x00000019|61 62|构建 E (2026-10-10) 67 字 / BID 0x19 (W66 = tcp_tx_frame.stat_winstall)"\n'
      '  "66|0x00000018|61 62|构建 D (2026-10-10) 66 字 / BID 0x18 (P7B-A7: W65 = mac_tx_10g.stat_tx_idle)"', 1)

E("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}   # 2026-10-10 构建 D (66 字; 原 0x00000017 = 构建 C / 更早 0x00000011 = r6-fix)",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}   # 2026-10-10 构建 E (67 字; 原 0x00000018 = 构建 D / 0x00000017 = 构建 C / 0x11 = r6-fix)", 1)
E("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}   # 2026-10-10 构建 D (66 字; 原 0x00000017 = 构建 C / 0x00000009 = WU 二轮)",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}   # 2026-10-10 构建 E (67 字; 原 0x00000018 = 构建 D / 0x17 = 构建 C / 0x09 = WU 二轮)", 1)

# ===========================================================================
# ② 取数器 p7b_snap.sh (NW / BID / 未实现地址注释 / NAME[65][66])
# ===========================================================================
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  "NW=${NW:-66}",
  "NW=${NW:-67}", 1)
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 66 ⇒ 0x128 (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 67 ⇒ 0x12C (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)", 1)
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}", 1)
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  " [63]=app_frmwait_cyc      [64]=app_bp_cyc\n",
  " [63]=app_frmwait_cyc      [64]=app_bp_cyc\n"
  " # ⭐ 构建 E (2026-10-10): W65/W66 —— **顺手补上两处表缺口** (上一轮实测 `full` 把它们\n"
  " #    打成 `?`: 表原只到 [64])。真值源 = `board/wrapper_p4.v` 装配段:\n"
  " #      W65 = mac_tx_10g.stat_tx_idle (线占空: S_IDLE 拍数) / W66 = tcp_tx_frame.stat_winstall (窗口门停顿拍数)。\n"
  " [65]=mac_tx_idle          [66]=tx_stat_winstall\n", 1)
E("_proj_pcie/p7b_biz/p7b_snap.sh",
  "# p7b_snap.sh -- 板侧 **63** 字快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 67 字 / BID 0x19**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ 构建 E (2026-10-10): 66 → **67** (W66 = tcp_tx_frame.stat_winstall; 未实现地址 0x128 → **0x12C**)。", 1)

# ===========================================================================
# ③ _proj_pcie 三个读侧脚本 (p6e_snap_check / p7b_gate4_accept / selftest / livefake / negctrl)
# ===========================================================================
E("_proj_pcie/p6e_snap_check.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}       # ⛔ 2026-10-10 构建 D: 原默认 0x00000017 (构建 C 65 字) / 0x0000000A (Stage C)",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}       # ⛔ 2026-10-10 构建 E: 原默认 0x00000018 (构建 D 66 字) / 0x17 (构建 C) / 0x0A (Stage C)", 1)
E("_proj_pcie/p6e_snap_check.sh",
  "SNAP_WORDS=${SNAP_WORDS:-66}",
  "SNAP_WORDS=${SNAP_WORDS:-67}", 1)
E("_proj_pcie/p6e_snap_check.sh",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 66 ⇒ 0x128 (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 67 ⇒ 0x12C (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)", 1)

E("_proj_pcie/p7b_gate4_accept.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}      # 构建 D = 0x18 (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 17 = 构建 C / 0x0A = Stage C)",
  "EXPECT_BID=${EXPECT_BID:-0x00000019}      # 构建 E = 0x19 (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x18 = 构建 D / 17 = 构建 C)", 1)
E("_proj_pcie/p7b_gate4_accept.sh",
  "SNAP_WORDS=${SNAP_WORDS:-66}",
  "SNAP_WORDS=${SNAP_WORDS:-67}", 1)
E("_proj_pcie/p7b_gate4_accept.sh",
  "# 66 ⇒ 0x128 (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "# 67 ⇒ 0x12C (66 ⇒ 0x128; 65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)", 1)

# ---- p6e_snap_selftest_fix2.sh (假板子: 尾段随几何走) ----
E("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "# ⚠️ 假板子的**几何必须与现役 RTL 同代** (= **66 字 / 未实现 0x128**; 2026-10-10 P7B-A7 构建 D;",
  "# ⚠️ 假板子的**几何必须与现役 RTL 同代** (= **67 字 / 未实现 0x12C**; 2026-10-10 构建 E;\n"
  "#    原句 = 66 字 / 0x128 (P7B-A7 构建 D);", 1)
E("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "  0X04) V=\\${FAKE_BID:-0x00000018};;   # 构建 D = 0x18 (⛔ 原 0x00000017 = 构建 C / 0x0000000A = Stage C);",
  "  0X04) V=\\${FAKE_BID:-0x00000019};;   # 构建 E = 0x19 (⛔ 原 0x18 = 构建 D / 0x17 = 构建 C / 0x0A = Stage C);", 1)
E("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "  0X124) V=0x00000000;;                                       # W65 mac_tx_10g.stat_tx_idle (66 字起; 构建 D)\n"
  "  0X128) V=0xffffffff;;                                       # 未实现地址 (66 字; 0xEC -> 0x114 -> 0x11C -> 0x124 -> **0x128**)",
  "  0X124) V=0x00000000;;                                       # W65 mac_tx_10g.stat_tx_idle (66 字起; 构建 D)\n"
  "  0X128) V=0x00000000;;                                       # W66 tcp_tx_frame.stat_winstall (67 字起; 构建 E)\n"
  "  0X12C) V=0xffffffff;;                                       # 未实现地址 (67 字; … -> 0x124 -> 0x128 -> **0x12C**)", 1)

# ---- p7b_gate4_selftest.sh (SW 档 + 假字表) ----
E("_proj_pcie/p7b_gate4_selftest.sh",
  "SW=${SNAP_WORDS:-66}",
  "SW=${SNAP_WORDS:-67}", 1)
E("_proj_pcie/p7b_gate4_selftest.sh",
  "#   SW ≥ 66 (2026-10-10 P7B-A7 构建 D 起) ⇒ 0x11C/0x120/0x124 也是**窗口内的真字**,\n"
  "#     `FAKE_UNIMPL` 挪到 **0x128**;",
  "#   SW ≥ 67 (2026-10-10 构建 E 起) ⇒ 0x11C/0x120/0x124/0x128 也是**窗口内的真字**,\n"
  "#     `FAKE_UNIMPL` 挪到 **0x12C**;\n"
  "#   SW ≥ 66 (P7B-A7 构建 D) ⇒ `FAKE_UNIMPL` 在 **0x128**;", 1)
E("_proj_pcie/p7b_gate4_selftest.sh",
  "if [ \"$SW\" -ge 66 ]; then\n"
  "  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)\n"
  "  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)\n"
  "  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)\n"
  "  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)\n"
  "  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)\n"
  "  0X128) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (66 字)'",
  "if [ \"$SW\" -ge 67 ]; then\n"
  "  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)\n"
  "  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)\n"
  "  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)\n"
  "  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)\n"
  "  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)\n"
  "  0X128) V=0;;     # W66 tcp_tx_frame.stat_winstall (窗口门停顿拍数, 建 E 新增)\n"
  "  0X12C) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (67 字)'\n"
  "elif [ \"$SW\" -ge 66 ]; then\n"
  "  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)\n"
  "  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)\n"
  "  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)\n"
  "  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)\n"
  "  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)\n"
  "  0X128) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (66 字)'", 1)
E("_proj_pcie/p7b_gate4_selftest.sh",
  "  0X04) V=\\${FAKE_BID:-0x00000018};;",
  "  0X04) V=\\${FAKE_BID:-0x00000019};;", 1)
E("_proj_pcie/p7b_gate4_selftest.sh",
  "而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x18** (构建 D 66 字 —— ⛔ 2026-10-10 同步轮:",
  "而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x19** (构建 E 67 字 —— ⛔ 2026-10-10 同步轮: 原 0x18 = 构建 D 66 字 /", 1)

# ---- p7b_gate4_livefake.sh (假对端: W 列表长度 + BID 表) ----
E("_proj_pcie/p7b_gate4_livefake.sh",
  "        + [0] * 15          # W51..W65 = P7B-BIZ/WU/构建C/构建D 新增字 (accept 只要求窗口齐全 + 无 0xffffffff)\n"
  "        #   ⛔ 2026-10-10 (构建 D): 14 -> **15** —— 构建 D 的远端请求是 66 字 (`for i in seq 0 65`),\n"
  "        #     `W[i]` 只到 W64 ⇒ 不同步会 `IndexError` (假对端直接崩 = \"整台安静\")。",
  "        + [0] * 16          # W51..W66 = P7B-BIZ/WU/构建C/构建D/构建E 新增字 (accept 只要求窗口齐全 + 无 0xffffffff)\n"
  "        #   ⛔ 2026-10-10 (构建 E): 15 -> **16** —— 构建 E 的远端请求是 67 字 (`for i in seq 0 66`),\n"
  "        #     `W[i]` 只到 W65 ⇒ 不同步会 `IndexError` (假对端直接崩 = \"整台安静\")。\n"
  "        #   ⛔ 2026-10-10 (构建 D): 14 -> **15** (构建 D 的远端请求是 66 字; 见下方 W 列表注释)。", 1)
E("_proj_pcie/p7b_gate4_livefake.sh",
  "    #   ⛔ 2026-10-10 (构建 D): 14 -> **15** (构建 D 的远端请求是 66 字; 见下方 W 列表注释)。\n"
  "    #   ⛔ 2026-10-10 (构建 C): 12 -> **14** —— 构建 C 的远端请求是 65 字 (`for i in seq 0 64`),\n",
  "    #   ⛔ 2026-10-10 (构建 C): 12 -> **14** —— 构建 C 的远端请求是 65 字 (`for i in seq 0 64`),\n", 1)
E("_proj_pcie/p7b_gate4_livefake.sh",
  "    #   ⛔ 2026-10-10 (构建 D): 加 **66 字那一代 = 0x18**; 兜底值同改 0x18 (现役代)。\n"
  "    bid = {66: \"0x00000018\", 65: \"0x00000017\", 63: \"0x0000000A\", 61: \"0x00000008\", 51: \"0x00000007\"}.get(nw, \"0x00000018\")",
  "    #   ⛔ 2026-10-10 (构建 D): 加 **66 字那一代 = 0x18**。\n"
  "    #   ⛔ 2026-10-10 (构建 E): 加 **67 字那一代 = 0x19**; 兜底值同改 0x19 (现役代)。\n"
  "    bid = {67: \"0x00000019\", 66: \"0x00000018\", 65: \"0x00000017\", 63: \"0x0000000A\", 61: \"0x00000008\", 51: \"0x00000007\"}.get(nw, \"0x00000019\")", 1)

# ---- p7b_gate4_negctrl.sh (合成夹具: 5 处, 照 D 轮的 apply_negctrl.py) ----
E("_proj_pcie/p7b_gate4_negctrl.sh",
  "# 几何: **66 字 (W0..W65)** —— P7B-A7 构建 D (2026-10-10, BID=0x18 / 未实现 0x128);",
  "# 几何: **67 字 (W0..W66)** —— 构建 E (2026-10-10, BID=0x19 / 未实现 0x12C);\n"
  "#       (原句: \"66 字 (W0..W65) —— P7B-A7 构建 D (2026-10-10, BID=0x18 / 未实现 0x128)\" = 历史代, 逐字保留于下)", 1)
E("_proj_pcie/p7b_gate4_negctrl.sh",
  "#       ⚠️ W51..W65 = P7B-BIZ/WU/构建C/构建D 新增字, 本夹具全填 0 (accept 只要求\"窗口齐全且无 0xffffffff\");",
  "#       ⚠️ W51..W66 = P7B-BIZ/WU/构建C/构建D/构建E 新增字, 本夹具全填 0 (accept 只要求\"窗口齐全且无 0xffffffff\");", 1)
E("_proj_pcie/p7b_gate4_negctrl.sh",
  'echo "MAGIC 0x50360001"; echo "BID 0x00000018"; echo "MARKER 0xdeadbeef"',
  'echo "MAGIC 0x50360001"; echo "BID 0x00000019"; echo "MARKER 0xdeadbeef"', 1)
E("_proj_pcie/p7b_gate4_negctrl.sh",
  "                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)   # W51..W65 (构建 D: W65 = mac_tx_10g.stat_tx_idle)",
  "                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)   # W51..W66 (构建 E: W66 = tcp_tx_frame.stat_winstall)", 1)
E("_proj_pcie/p7b_gate4_negctrl.sh",
  "for (( i = 0; i < 66; i++ ))",
  "for (( i = 0; i < 67; i++ ))", 1)
E("_proj_pcie/p7b_gate4_negctrl.sh",
  "shift1(){ awk -v NW=66 ",
  "shift1(){ awk -v NW=67 ", 1)

# ===========================================================================
# ④ final_state.sh (未实现地址 + W66 读数行)
# ===========================================================================
E("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  'echo "MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x128) gen=$(( (s >> 16) & 0xffff ))"',
  'echo "MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x12c) gen=$(( (s >> 16) & 0xffff ))"', 1)
E("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **65 字 (P7B-GAP9-TX, 2026-10-10 起) ⇒ 0x124** (word 73);",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **67 字 (构建 E, 2026-10-10 起) ⇒ 0x12C** (word 75);\n"
  "#    66 字 (构建 D) = 0x128 (word 74); 65 字 (P7B-GAP9-TX) = 0x124 (word 73);", 1)
E("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  'echo "W63=$(rd 0x11c) W64=$(rd 0x120) W65=$(rd 0x124)  # 构建 C: app 停滞计数; 构建 D: W65 = mac_tx_10g.stat_tx_idle"',
  'echo "W63=$(rd 0x11c) W64=$(rd 0x120) W65=$(rd 0x124)  # 构建 C: app 停滞计数; 构建 D: W65 = mac_tx_10g.stat_tx_idle"\n'
  'echo "W66=$(rd 0x128)  # 构建 E: W66 = tcp_tx_frame.stat_winstall (帧器侧窗口门停顿拍数)"', 1)

# ===========================================================================
# ⑤ sim 侧 TB (BID / 未实现地址) + p7b_chain
# ===========================================================================
E("sim/p6e_pcie/tb_p6e_pcie_counters.v",
  "chk(\"0b BUILD_ID (构建 D 66-word = 0x18; 原 65-word=17 / 63-word=9)\", v, 32'h00000018);",
  "chk(\"0b BUILD_ID (构建 E 67-word = 0x19; 原 66-word=0x18 / 65-word=17 / 63-word=9)\", v, 32'h00000019);", 1)
E("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "chk(\"2  BUILD_ID (构建 D 66 字=0x18; 原 65 字=17 / 63 字=9)\", v, 32'h00000018);",
  "chk(\"2  BUILD_ID (构建 E 67 字=0x19; 原 66 字=0x18 / 65 字=17 / 63 字=9)\", v, 32'h00000019);", 1)
E("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "        chk(\"9  未实现地址 0x128 ⇒ rresp = SLVERR\", {30'd0, u_dut.u_pcie_xdma.last_rresp}, 32'd2);",
  "        chk(\"9  未实现地址 0x12C ⇒ rresp = SLVERR\", {30'd0, u_dut.u_pcie_xdma.last_rresp}, 32'd2);", 1)
E("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "        u_dut.u_pcie_xdma.axil_read(32'h128, v);",
  "        u_dut.u_pcie_xdma.axil_read(32'h12C, v);", 1)
E("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "        // ⛔ 2026-10-10 (构建 D): 窗口 65 → **66 字** (`SNAP_NW_P6E = 66`) ⇒ 末字 W65 @ 0x124\n"
  "        //    ⇒ 未实现地址 = 0x20 + 4*66 = **0x128** (word 74)。0x124 现在是窗口内的真字。",
  "        // ⛔ 2026-10-10 (构建 E): 窗口 66 → **67 字** (`SNAP_NW_P6E = 67`) ⇒ 末字 W66 @ 0x128\n"
  "        //    ⇒ 未实现地址 = 0x20 + 4*67 = **0x12C** (word 75)。0x128 现在是窗口内的真字。", 1)
E("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  "        u_dut.u_pcie_xdma.axil_read(32'h128, v);\n        chk(\"7b 0x128 reads 0 no wrap\",",
  "        u_dut.u_pcie_xdma.axil_read(32'h12C, v);\n        chk(\"7b 0x12C reads 0 no wrap\",", 1)
E("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  "\"axi_regs decode; 66-word bound (原 65 字/0x124, 63 字/0x11C; 2026-10-10 订正)\");",
  "\"axi_regs decode; 67-word bound (原 66 字/0x128, 65 字/0x124, 63 字/0x11C; 2026-10-10 订正)\");", 1)

# ===========================================================================
# ⑥ p7b_biz_win 三个守卫 (tb_biz_win.v / run_tb_biz_win.bat / run_xvlog_wrapper.bat
#    / sim/p5wu_p1p2/run_xvlog_wrapper63.bat)
# ===========================================================================
E("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "// tb_biz_win.v — P7B-BIZ 快照窗口的**逐字读回**门 (axi_regs @ SNAP_NW=66; P7B-A7 构建 D 起;",
  "// tb_biz_win.v — P7B-BIZ 快照窗口的**逐字读回**门 (axi_regs @ SNAP_NW=67; 构建 E 起;", 1)
E("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "    localparam integer NW = 66;  // = wrapper 的 SNAP_NW_P6E (P7B-A7 构建 D, 2026-10-10; 原 61/63/65)",
  "    localparam integer NW = 67;  // = wrapper 的 SNAP_NW_P6E (构建 E, 2026-10-10; 原 61/63/65/66)", 1)
E("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "        chk(\"5a 末字 (0x20+4*(NW-1) = 0x124 @NW=66) 读得到\", v, code_of(NW-1));",
  "        chk(\"5a 末字 (0x20+4*(NW-1) = 0x128 @NW=67) 读得到\", v, code_of(NW-1));", 1)
E("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "        chk(\"6a 未实现地址 (0x20+4*NW = 0x128 @NW=66) 回 0\", v, 32'h0000_0000);",
  "        chk(\"6a 未实现地址 (0x20+4*NW = 0x12C @NW=67) 回 0\", v, 32'h0000_0000);", 1)
E("_proj_10g/notes/p7b_biz_win/run_tb_biz_win.bat",
  'findstr /C:"SNAP_NW_P6E = 66" "%ROOT%\\board\\wrapper_p4.v" >NUL || ( echo [FINGERPRINT FAIL] wrapper is not 66-word & exit /b 92 )',
  'findstr /C:"SNAP_NW_P6E = 67" "%ROOT%\\board\\wrapper_p4.v" >NUL || ( echo [FINGERPRINT FAIL] wrapper is not 67-word & exit /b 92 )', 1)
E("_proj_10g/notes/p7b_biz_win/run_tb_biz_win.bat",
  "REM 2026-10-10 (P7B-GAP9-TX): fingerprint 61 -> 65. It had already gone stale at 63",
  "REM 2026-10-10 (构建 E): fingerprint 66 -> 67.\n"
  "REM 2026-10-10 (P7B-GAP9-TX): fingerprint 61 -> 65. It had already gone stale at 63", 1)
E("_proj_10g/notes/p7b_biz_win/run_xvlog_wrapper.bat",
  'findstr /C:"SNAP_NW_P6E = 66" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 66-word version & exit /b 92 )',
  'findstr /C:"SNAP_NW_P6E = 67" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 67-word version & exit /b 92 )', 1)
E("sim/p5wu_p1p2/run_xvlog_wrapper63.bat",
  'findstr /C:"SNAP_NW_P6E = 66" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 66-word version & exit /b 92 )',
  'findstr /C:"SNAP_NW_P6E = 67" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 67-word version & exit /b 92 )', 1)


def main():
    check = "--check" in sys.argv[1:]
    fails = []
    for rel, old, new, n in EDITS:
        p = os.path.join(REPO, rel.replace("/", os.sep))
        b, nl = rd(p)
        if nl != b"\n":
            old2 = old.replace("\r\n", "\n").replace("\n", nl.decode())
            new2 = new.replace("\r\n", "\n").replace("\n", nl.decode())
        else:
            old2 = old.replace("\r\n", "\n")
            new2 = new.replace("\r\n", "\n")
        s = b.decode("utf-8")
        k = s.count(old2)
        tag = "OK  " if k == n else "FAIL"
        print("%s %-52s hits=%d/%d  %s" % (tag, rel, k, n, old.split("\n")[0][:44]))
        if k != n:
            fails.append((rel, k, n, old.split("\n")[0][:80]))
            continue
        if not check:
            io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old2, new2))
    print("APPLY_READSIDE %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
