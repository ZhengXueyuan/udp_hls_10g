#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B-A7 读侧脚本 65->66 字同步 —— 显式清单 (每条断言命中数, 不做任何通配替换).
   只改**功能默认值**与就地订正的注释; 历史注释一律保留 (加 "构建 D" 注记)。
   行尾: 插入行用文件自身的行尾风格 (CRLF 文件插 CRLF)。"""
import io, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = r"D:\repo\XCKU5PMini\udp_hls_10g"

def rd(p):
    b = open(p, "rb").read()
    return b, (b"\r\n" if b.count(b"\r\n") else b"\n")

EDITS = [
 # ---- j6_r6fix.sh (GEOM_TIERS 档表 + 默认档) ----
 ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh", "NW=${NW:-65}", "NW=${NW:-66}", 1),
 ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000017}   # 2026-10-10 构建 C (65 字; 原 0x00000011 = r6-fix / 更早 0x0000000A = Stage C)",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}   # 2026-10-10 构建 D (66 字; 原 0x00000017 = 构建 C / 更早 0x00000011 = r6-fix)", 1),
 ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
  '  "65|0x00000017|61 62|构建 C (2026-10-10) 65 字 / BID 0x17"',
  '  "66|0x00000018|61 62|构建 D (2026-10-10) 66 字 / BID 0x18 (P7B-A7: W65 = mac_tx_10g.stat_tx_idle)"\n'
  '  "65|0x00000017|61 62|构建 C (2026-10-10) 65 字 / BID 0x17"', 1),
 # ---- tcpreg_j6.sh ----
 ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh", "NW=${NW:-65}", "NW=${NW:-66}", 1),
 ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000017}   # 2026-10-10 构建 C (65 字; 原 0x00000009 = P7B-WU 二轮 / Build 2)",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}   # 2026-10-10 构建 D (66 字; 原 0x00000017 = 构建 C / 0x00000009 = WU 二轮)", 1),
 ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",
  '  "65|0x00000017|61 62|构建 C (2026-10-10) 65 字 / BID 0x17"',
  '  "66|0x00000018|61 62|构建 D (2026-10-10) 66 字 / BID 0x18 (P7B-A7: W65 = mac_tx_10g.stat_tx_idle)"\n'
  '  "65|0x00000017|61 62|构建 C (2026-10-10) 65 字 / BID 0x17"', 1),
 # ---- biz_win: tb_biz_win.v (NW) + 两个 bat 的指纹 ----
 ("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "    localparam integer NW = 65;  // = wrapper 的 SNAP_NW_P6E (P7B-GAP9-TX, 2026-10-10; 原 61/63)",
  "    localparam integer NW = 66;  // = wrapper 的 SNAP_NW_P6E (P7B-A7 构建 D, 2026-10-10; 原 61/63/65)", 1),
 ("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  'chk("5a 末字 (0x20+4*(NW-1) = 0x120 @NW=65) 读得到", v, code_of(NW-1));',
  'chk("5a 末字 (0x20+4*(NW-1) = 0x124 @NW=66) 读得到", v, code_of(NW-1));', 1),
 ("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  'chk("6a 未实现地址 (0x20+4*NW = 0x124 @NW=65) 回 0", v, 32\'h0000_0000);',
  'chk("6a 未实现地址 (0x20+4*NW = 0x128 @NW=66) 回 0", v, 32\'h0000_0000);', 1),
 ("_proj_10g/notes/p7b_biz_win/tb_biz_win.v",
  "// tb_biz_win.v — P7B-BIZ 快照窗口的**逐字读回**门 (axi_regs @ SNAP_NW=65; P7B-GAP9-TX 起;",
  "// tb_biz_win.v — P7B-BIZ 快照窗口的**逐字读回**门 (axi_regs @ SNAP_NW=66; P7B-A7 构建 D 起;", 1),
 ("_proj_10g/notes/p7b_biz_win/run_tb_biz_win.bat",
  'findstr /C:"SNAP_NW_P6E = 65" "%ROOT%\\board\\wrapper_p4.v" >NUL || ( echo [FINGERPRINT FAIL] wrapper is not 65-word & exit /b 92 )',
  'findstr /C:"SNAP_NW_P6E = 66" "%ROOT%\\board\\wrapper_p4.v" >NUL || ( echo [FINGERPRINT FAIL] wrapper is not 66-word & exit /b 92 )', 1),
 ("_proj_10g/notes/p7b_biz_win/run_xvlog_wrapper.bat",
  'findstr /C:"SNAP_NW_P6E = 65" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 65-word version & exit /b 92 )',
  'findstr /C:"SNAP_NW_P6E = 66" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 66-word version & exit /b 92 )', 1),
 ("sim/p5wu_p1p2/run_xvlog_wrapper63.bat",
  'findstr /C:"SNAP_NW_P6E = 65" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 65-word version & exit /b 92 )',
  'findstr /C:"SNAP_NW_P6E = 66" "%SRCFILE%" >NUL || ( echo [FINGERPRINT FAIL] source is not the 66-word version & exit /b 92 )', 1),
 # ---- _proj_pcie 读侧 6 件 ----
 ("_proj_pcie/p6e_snap_check.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000017}       # ⛔ 2026-10-10 构建 C: 原默认 0x0000000A (P7b Stage C 63 字)",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}       # ⛔ 2026-10-10 构建 D: 原默认 0x00000017 (构建 C 65 字) / 0x0000000A (Stage C)", 1),
 ("_proj_pcie/p6e_snap_check.sh", "SNAP_WORDS=${SNAP_WORDS:-65}", "SNAP_WORDS=${SNAP_WORDS:-66}", 1),
 ("_proj_pcie/p6e_snap_check.sh",
  "# 65 ⇒ 0x124 (63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "# 66 ⇒ 0x128 (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)", 1),
 ("_proj_pcie/p6e_snap_check.sh",
  "#              ⛔ 2026-10-10 订正 (构建 C 门同步轮): **RTL 当前值 = 17 (65 字 / 未实现 0x124)**",
  "#              ⛔ 2026-10-10 订正 (构建 D 门同步轮): **RTL 当前值 = 0x18 (66 字 / 未实现 0x128)**\n"
  "#              (原句 \"= 17 (65 字 / 0x124)\" = 构建 C 那一代; 判据语义零改动)", 1),
 ("_proj_pcie/p7b_biz/p7b_snap.sh", "NW=${NW:-65}", "NW=${NW:-66}", 1),
 ("_proj_pcie/p7b_biz/p7b_snap.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000017}", "EXPECT_BID=${EXPECT_BID:-0x00000018}", 1),
 ("_proj_pcie/p7b_biz/p7b_snap.sh",
  "# 65 ⇒ 0x124 (63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "# 66 ⇒ 0x128 (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)", 1),
 ("_proj_pcie/p7b_gate4_accept.sh",
  "EXPECT_BID=${EXPECT_BID:-0x00000017}      # 构建 C = 17 (源码 board/wrapper_p4.v 的 BUILD_ID_V)",
  "EXPECT_BID=${EXPECT_BID:-0x00000018}      # 构建 D = 0x18 (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 17 = 构建 C / 0x0A = Stage C)", 1),
 ("_proj_pcie/p7b_gate4_accept.sh", "SNAP_WORDS=${SNAP_WORDS:-65}", "SNAP_WORDS=${SNAP_WORDS:-66}", 1),
 ("_proj_pcie/p7b_gate4_accept.sh",
  "# 65 ⇒ 0x124 (63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "# 66 ⇒ 0x128 (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)", 1),
 ("_proj_pcie/p7b_gate4_accept.sh",
  "#         现役 = **65 字 / 未实现 0x124 / BID 17** (源码 `board/wrapper_p4.v`: `SNAP_NW_P6E = 65` /",
  "#         现役 = **66 字 / 未实现 0x128 / BID 0x18** (构建 D; ⛔ 原句 = 65 字 / 0x124 / BID 17 = 构建 C)\n"
  "#         (源码 `board/wrapper_p4.v`: `SNAP_NW_P6E = 66` /", 1),
 # ---- final_state.sh ----
 ("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  'echo "MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x124) gen=$(( (s >> 16) & 0xffff ))"',
  'echo "MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x128) gen=$(( (s >> 16) & 0xffff ))"', 1),
 ("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  'echo "W61=$(rd 0x114) W62=$(rd 0x118)  # P7B-WU 二轮新增 (stat_wu / rx_occ_bytes)"',
  'echo "W61=$(rd 0x114) W62=$(rd 0x118)  # P7B-WU 二轮新增 (stat_wu / rx_occ_bytes)"\n'
  'echo "W63=$(rd 0x11c) W64=$(rd 0x120) W65=$(rd 0x124)  # 构建 C: app 停滞计数; 构建 D: W65 = mac_tx_10g.stat_tx_idle"', 1),
 # ---- sim 侧 TB (BID / 未实现地址) ----
 ("sim/p6e_pcie/tb_p6e_pcie_counters.v",
  'chk("0b BUILD_ID (构建 C 65-word = 17; 原 63-word=9)", v, 32\'h00000017);',
  'chk("0b BUILD_ID (构建 D 66-word = 0x18; 原 65-word=17 / 63-word=9)", v, 32\'h00000018);', 1),
 ("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  'chk("2  BUILD_ID (构建 C 65 字=17; 原 63 字=9)", v, 32\'h00000017);',
  'chk("2  BUILD_ID (构建 D 66 字=0x18; 原 65 字=17 / 63 字=9)", v, 32\'h00000018);', 1),
 ("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  'chk("9  未实现地址 0x124 ⇒ rresp = SLVERR", {30\'d0, u_dut.u_pcie_xdma.last_rresp}, 32\'d2);',
  'chk("9  未实现地址 0x128 ⇒ rresp = SLVERR", {30\'d0, u_dut.u_pcie_xdma.last_rresp}, 32\'d2);', 1),
 ("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  "        u_dut.u_pcie_xdma.axil_read(32'h124, v);\n        chk(\"7b 0x124 reads 0 no wrap\",",
  "        u_dut.u_pcie_xdma.axil_read(32'h128, v);\n        chk(\"7b 0x128 reads 0 no wrap\",", 1),
 ("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  '"axi_regs decode; 65-word bound (原 63 字/0x11C; 2026-10-10 订正)");',
  '"axi_regs decode; 66-word bound (原 65 字/0x124, 63 字/0x11C; 2026-10-10 订正)");', 1),
]

fails = []
for rel, old, new, n in EDITS:
    p = os.path.join(REPO, rel.replace("/", os.sep))
    b, nl = rd(p)
    if nl != b"\n":
        new = new.replace("\n", nl.decode())
    s = b.decode("utf-8")
    k = s.count(old)
    if k != n:
        fails.append((rel, k, n, old[:60]))
        continue
    io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old, new))
    print("OK   %-52s hits=%d  %s" % (rel, k, old[:64].replace("\n", "\\n")))

for f in fails:
    print("FAIL %s hits=%d expect=%d  %r" % (f[0], f[1], f[2], f[3]))
print("EDGES %s (%d edits, %d fail)" % ("OK" if not fails else "FAIL", len(EDITS), len(fails)))
sys.exit(1 if fails else 0)
