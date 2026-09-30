# -*- coding: utf-8 -*-
"""Swap the PCS socket: pcs64 (real, synth) vs p7b_pcs_stub (sim only)."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/board/wrapper_p4.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

old = '    pcs64 u_pcs (\n'
assert s.count(old) == 1, s.count(old)
new = ('    // ⚠️ PCS socket = 唯一在"仿真 vs 综合"之间换掉的东西 (端口表**逐一相同**):\n'
       '    //   综合 = 真核 `pcs64` (加密 GT IP, 本工程从未在 xsim 里跑过);\n'
       '    //   仿真 = `p7b_pcs_stub` (行为级 XGMII 泵, 只造字节流与两个 156.25MHz 钟)。\n'
       '    //   ⇒ 除这一个实例, MAC / CDC / 数据面 / 快照的接线两边**逐字相同** ——\n'
       '    //   这正是"ifdef 里的接线错只有真 wrapper 全链门能抓"能成立的前提。\n'
       '    //   (与 P6B_SIM_CLKGEN 把 MMCM 换成行为级模型是同一个手法。)\n'
       '`ifdef P7B_SIM_NOPCS\n'
       '    p7b_pcs_stub u_pcs (\n'
       '`else\n'
       '    pcs64 u_pcs (\n'
       '`endif\n')
s = s.replace(old, new)
io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('pcs socket patched')
