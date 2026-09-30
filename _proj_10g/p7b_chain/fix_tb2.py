# -*- coding: utf-8 -*-
"""1) print-friendly chk labels (xsim's %0s truncates a 256-bit vector to its
      LAST 32 characters -> every label must be <= 28 chars);
   2) CRC convention fix: the value on the wire is `~internal` (zlib.crc32),
      and crc32("123456789") == 0xCBF43926 is the POST-inversion value.
   The full statement + expectation source for every label is kept in the
   header table of the TB (and in the round report)."""
import io, re

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

# ---- CRC fixes -------------------------------------------------------------
old = '''        v = 32'hFFFFFFFF;
        v = crc32_byte(v,8'h31); v = crc32_byte(v,8'h32); v = crc32_byte(v,8'h33);
        v = crc32_byte(v,8'h34); v = crc32_byte(v,8'h35); v = crc32_byte(v,8'h36);
        v = crc32_byte(v,8'h37); v = crc32_byte(v,8'h38); v = crc32_byte(v,8'h39);
        chk("0a crc32(\\"123456789\\") == 0xCBF43926", v === 32'hCBF43926,
            "standard check vector (802.3 clause 3.2.9)");'''
new = '''        v = 32'hFFFFFFFF;
        v = crc32_byte(v,8'h31); v = crc32_byte(v,8'h32); v = crc32_byte(v,8'h33);
        v = crc32_byte(v,8'h34); v = crc32_byte(v,8'h35); v = crc32_byte(v,8'h36);
        v = crc32_byte(v,8'h37); v = crc32_byte(v,8'h38); v = crc32_byte(v,8'h39);
        // ⚠️ crc32_byte 给的是**内部状态** (无终值取反); 标准校验向量的值
        //    0xCBF43926 是**取反后**的 (zlib.crc32) ⇒ 必须 ~v 再比。
        //    这与工程约定一致: 线上 FCS = ~internal, 残留 = 0xDEBB20E3。
        chk("0a crc32_std(123456789)=CBF43926", (~v) === 32'hCBF43926,
            "802.3 check vector (zlib=~internal)");'''
assert s.count(old) == 1, ('crc0a', s.count(old))
s = s.replace(old, new)

old = '''        m = v;
        v = crc32_byte(v, m[7:0]);   v = crc32_byte(v, m[15:8]);
        v = crc32_byte(v, m[23:16]); v = crc32_byte(v, m[31:24]);
        chk("0b frame residue == 0xDEBB20E3 (NOT 0xC704DD7B)", v === 32'hDEBB20E3,
            "project rule: reflected magic; 0xC704DD7B is the big-endian one");'''
new = '''        m = ~v;                                   // 线上 FCS = ~internal, LSB first
        v = crc32_byte(v, m[7:0]);   v = crc32_byte(v, m[15:8]);
        v = crc32_byte(v, m[23:16]); v = crc32_byte(v, m[31:24]);
        chk("0b residue == DEBB20E3", v === 32'hDEBB20E3,
            "project rule: 0xDEBB20E3, not 0xC704DD7B");'''
assert s.count(old) == 1, ('crc0b', s.count(old))
s = s.replace(old, new)

old = '''            fcs_calc = 32'hFFFFFFFF;
            for (i = 0; i < n; i = i + 1) fcs_calc = crc32_byte(fcs_calc, PAT[i]);'''
new = '''            fcs_calc = 32'hFFFFFFFF;
            for (i = 0; i < n; i = i + 1) fcs_calc = crc32_byte(fcs_calc, PAT[i]);
            fcs_calc = ~fcs_calc;      // 线上 FCS = ~internal (与 MAC 的写法一致)'''
assert s.count(old) == 1, ('crcfcs', s.count(old))
s = s.replace(old, new)

# ---- label shortening ------------------------------------------------------
LAB = {
 '0a crc32(\\"123456789\\") == 0xCBF43926': '0a crc32_std(123456789)=CBF43926',
 '0b frame residue == 0xDEBB20E3 (NOT 0xC704DD7B)': '0b residue==DEBB20E3',
 '0c PCS stub link released (user_rx_reset_1 == 0)': '0c stub link released',
 '0d SFP2 TX_DIS driven LOW (transmitter enabled)': '0d SFP2 TX_DIS low',
 '1a RX delivered a frame': '1a RX delivered >=1 frame',
 '1b RX first byte == content[0] (tdata[63:56], NO mirror in the contract)': '1b RX first byte==content[0]',
 '1c RX first byte is NOT the XGMII lane7 byte (would be PAT[7] if mis-mirrored)': '1c RX 1st byte!=lane7 byte',
 '2a min frame (content 60B) delivers exactly 60 bytes': '2a min frame -> 60 bytes',
 '2b max frame (content 1514B) delivers exactly 1514 bytes': '2b max frame -> 1514 bytes',
 '2c \u03a3popc(tkeep) conservation over 1+2a+2b frames': '2c Sum popc conservation',
 '2d non-multiple-of-8 frames (63+65) deliver exactly 128 bytes': '2d 63+65 -> 128 bytes',
 '2e frames counted == 2 (no merge, no split)': '2e frames==2 no merge',
 '3a good FCS does not increment stat_crc_err': '3a good FCS crc_err same',
 '3b good FCS frame is delivered (64 bytes)': '3b good FCS -> 64 bytes',
 '3c bad FCS increments stat_crc_err by exactly 1': '3c bad FCS crc_err +1',
 '3d bad-FCS frame is still delivered (FCS stripped, flagged via tcrs)': '3d bad FCS still delivered',
 '3e /E/ inside the frame increments mac_rx stat_rx_er_words': '3e /E/ -> rx_er_words +',
 '3f stat_rx_fifo_ovf stays 0 across all RX tests (healthy)': '3f stat_fifo_ovf==0',
 '4a back-to-back x3 with zero IFG -> exactly 3 frames': '4a b2b x3 -> 3 frames',
 '4b back-to-back x3 -> 180 bytes total': '4b b2b x3 -> 180 bytes',
 '5a F4(a) space gate: drops recorded while the downstream is stalled': '5a F4 drops recorded',
 '5b F4(b) TERM word observed in the delivered stream': '5b F4 TERM word seen',
 '5c every delivered frame is <= 1514 content bytes (no merge)': '5c no frame > 1514B',
 '5d F4 drop counters are monotone witnesses, not noise': '5d F4 drop count > 0',
 '5e recovery: the next frame is delivered byte-exact': '5e recovery byte-exact',
 '6a TX: exactly one frame on the wire (no ghost, no split)': '6a TX 1 wire frame',
 '6b TX: first wire word has /S/ at lane0 (0xFB, c[0]=1)': '6b TX /S/ at lane0',
 '6c TX: preamble = 0x55 x6 + 0xD5 in the rest of the first word': '6c TX preamble word',
 '6d TX: preamble in the wire frame == 55 x6 + D5': '6d TX wf preamble',
 '6e TX: content bytes are lane-ordered (no mirror)': '6e TX content lane order',
 '6f TX: 2nd content word is lane-ordered': '6f TX w2 lane order',
 '6d TX: preamble in the wire frame (GATED OFF: wf_cnt != 1)': '6d TX wf preamble OFF',
 '6e TX: content lane order (GATED OFF: wf_cnt != 1)': '6e TX lane order OFF',
 '6f TX: 2nd content word lane order (GATED OFF)': '6f TX w2 order OFF',
 '7 W36 = mac_rx_10g.stat_rx_words': '7 W36 rx_words',
 '7 W37 = mac_rx_10g.stat_rx_pay_bytes': '7 W37 rx_pay_bytes',
 '7 W38 = u_rxcdc.ovf_cnt (wr domain = FE)': '7 W38 rxcdc.ovf_cnt',
 '7 W39[2] = PCS block_lock': '7 W39[2] block_lock',
 '7 W39[4] = PCS hi_ber': '7 W39[4] hi_ber',
 '7 W41 = mac_tx_10g.stat_flush_words': '7 W41 stat_flush_words',
 '7 W42 = mac_tx_10g.stat_flush_done': '7 W42 stat_flush_done',
 '7 W43 = mac_tx_10g.stat_tx_words': '7 W43 stat_tx_words',
 '7 W44 = mac_tx_10g.stat_tx_ctrl_char': '7 W44 stat_tx_ctrl_char',
 '7 W45 = u_txcdc.ovf_cnt (wr domain = DP)': '7 W45 txcdc.ovf_cnt',
 '7 W46 = rx_classify dbg_stat_ovf': '7 W46 cls dbg_stat_ovf',
 '7 W47 = rx_classify dbg_stat_route_ovf': '7 W47 cls route_ovf',
 '7 W48 = rx_classify dbg_stat_stall_in': '7 W48 cls stall_in',
 '7 W49 = rx_classify dbg_occ (5b, zero-extended)': '7 W49 cls dbg_occ',
 '7 W50 = tx_mii_clk activity (LAST slot of the 51-word map)': '7 W50 tx_clk_act',
 '7b unimplemented 0xEC reads 0 with SLVERR (no wrap-around)': '7b 0xEC reads 0 no wrap',
}
for a, b in LAB.items():
    s = s.replace('"' + a + '"', '"' + b + '"')

# ---- src strings: shorten the long ones ------------------------------------
SRC = {
 'standard check vector (802.3 clause 3.2.9)': '802.3 check vector',
 'project rule: reflected magic; 0xC704DD7B is the big-endian one': 'project rule 0xDEBB20E3',
 'stimulus precondition': 'stim precond',
 'P7B_GATE1 5.8 three-state experiment': 'P7B_GATE1 5.8',
 'stimulus precondition (non-vacuous denominator)': 'stim precond (nonvacuous)',
 'injected byte array + P7B_GATE1 C.2 mirror table': 'injected bytes + GATE1 C.2',
 'negative: distinct first 8 content bytes': 'neg: 8 distinct bytes',
 '802.3 Clause 4.4 / injected length': '802.3 Cl.4.4 / injected',
 'contract: delivered bytes == injected content bytes': 'contract: bytes==injected',
 '3+3 derived: injected lengths': 'derived: 63+65',
 'contract: one TLAST per frame': 'contract: 1 TLAST/frame',
 'injected FCS == TB-computed CRC32': 'inj FCS == TB CRC32',
 'contract: tcrs=1 on TLAST': 'contract: tcrs=1',
 'injected: FCS field replaced by 0x00000000': 'inj: FCS = 0x00000000',
 'contract: crc error is a flag, not a drop': 'contract: crc is a flag',
 'XGMII /E/ (0xFE,c=1) injected at content byte 10': 'inj /E/ at content byte 10',
 'mac_rx_10g: structurally 0': 'mac_rx_10g: structural 0',
 'derived: 3 injected frames, no IFG words': 'derived: 3 frames, no IFG',
 'derived: 3 x 60': 'derived: 3x60',
 '40 x 1514B into a 16-word FIFO with tready=0': '40x1514B, 16w FIFO, tready=0',
 'mac_rx_64.v TERM tuple {tkeep=0,tlast=1,tcrs=0,terr=1} verbatim': 'TERM tuple verbatim',
 'derived: max injected content length': 'derived: max content 1514',
 'derived: 64 content bytes, first byte PAT[0]': 'derived: 64B, first=PAT[0]',
 'derived: one tlast-terminated input frame': 'derived: 1 tlast frame',
 'vendor example :995/:1147-1149 + P7B_GATE1 C.4': 'vendor :995 + GATE1 C.4',
 'vendor example :995 literal': 'vendor :995 literal',
 'contract: tdata[63:56] is the frame\'s first byte': 'contract: tdata[63:56] 1st',
 'derived: tdata[63:56]=0x44 ... tdata[7:0]=0x11': 'derived: 0x44..0x11',
 'diagnostic gate': 'diagnostic gate (off)',
 'forced producer': 'forced producer node',
 'forced producer (bit field)': 'forced producer bit',
 'axi_regs read-side decode; 51-word map bound': 'axi_regs decode; 51-word bound',
}
for a, b in SRC.items():
    s = s.replace('"' + a + '"', '"' + b + '"')

# ---- add the judgement table to the header ---------------------------------
tbl = '''// ---------------------------------------------------------------------------
// \u5224\u636e\u8868 (\u7b80\u6807\u7b7e \u2192 \u5b8c\u6574\u9648\u8ff0 + \u671f\u671b\u6765\u6e90; \u65e5\u5fd7\u91cc\u53ea\u6253\u7b80\u6807\u7b7e)
//   0a crc32_std("123456789") == 0xCBF43926            | 802.3 \u6807\u51c6\u6821\u9a8c\u5411\u91cf (zlib=\u53d6\u53cd\u540e)
//   0b \u5e27\u5185\u5bb9+\u5176 FCS \u7684\u6b8b\u7559 == 0xDEBB20E3           | \u5de5\u7a0b\u94c1\u5f8b (0xC704DD7B \u662f\u5927\u7aef\u9b54\u6570)
//   0c PCS stub \u653e\u884c (user_rx_reset_1==0)                 | \u6fc0\u52b1\u524d\u63d0
//   0d SFP2 TX_DIS \u9a71\u52a8\u4e3a\u4f4e                             | GATE1 5.8 \u4e09\u6001\u5224\u522b\u5b9e\u9a8c
//   1a RX \u81f3\u5c11\u4ea4\u4ed8 1 \u5e27                              | \u6fc0\u52b1\u524d\u63d0 (\u975e\u771f\u7a7a\u5206\u6bcd)
//   1b RX \u9996\u5b57\u8282 == \u5185\u5bb9[0] (tdata[63:56])             | \u6ce8\u5165\u5b57\u8282\u6570\u7ec4 + GATE1 \u00a7C.2 \u955c\u50cf\u8868
//   1c RX \u9996\u5b57\u8282 != XGMII lane7 \u90a3\u4e2a\u5b57\u8282              | \u8d1f\u5411: \u524d 8 \u4e2a\u5185\u5bb9\u5b57\u8282\u4e24\u4e24\u4e0d\u540c
//   2a/2b \u6700\u5c0f/\u6700\u5927\u5e27\u4ea4\u4ed8\u5b57\u8282\u6570 == 60/1514           | 802.3 Cl.4.4 + \u6ce8\u5165\u957f\u5ea6
//   2c \u03a3popc(tkeep) \u5b88\u6052                                  | \u5408\u540c: \u4ea4\u4ed8\u5b57\u8282 == \u6ce8\u5165\u5185\u5bb9\u5b57\u8282
//   2d 63+65 \u975e 8 \u500d\u6570\u5e27 \u2192 128 \u5b57\u8282                       | \u6ce8\u5165\u957f\u5ea6
//   2e \u5e27\u6570 == 2 (\u4e0d\u5408\u5e76\u4e0d\u62c6\u5206)                          | \u5408\u540c: \u6bcf\u5e27 1 \u4e2a TLAST
//   3a \u597d FCS \u4e0d\u52a0 stat_crc_err                           | \u6ce8\u5165 FCS == TB \u7b97\u7684 CRC32
//   3b \u597d FCS \u5e27\u88ab\u4ea4\u4ed8 (64B)                           | \u5408\u540c: tcrs=1
//   3c \u574f FCS \u4f7f stat_crc_err +1                            | \u6ce8\u5165: FCS \u5b57\u6bb5\u6539\u6210 0
//   3d \u574f FCS \u5e27\u4ecd\u88ab\u4ea4\u4ed8 (\u6807\u5fd7\u800c\u975e\u4e22\u5f03)                 | \u5408\u540c: crc \u9519\u662f\u6807\u5fd7
//   3e \u5e27\u5185 /E/ \u4f7f stat_rx_er_words \u589e                   | \u6ce8\u5165 /E/ \u5728\u5185\u5bb9\u7b2c 10 \u5b57\u8282
//   3f stat_rx_fifo_ovf \u6052 0                                | mac_rx_10g \u7ed3\u6784\u4e0a\u6052 0
//   4a/4b \u96f6\u95f4\u9694\u80cc\u9760\u80cc 3 \u5e27 \u2192 3 \u5e27 / 180 \u5b57\u8282         | derive: 3 \u00d7 60
//   5a F4(a) \u4e0b\u6e38\u505c\u6446\u65f6\u6709\u4e22\u5e27\u8ba1\u6570                     | 40\u00d71514B \u5bf9 16 \u5b57 FIFO
//   5b F4(b) \u4ea4\u4ed8\u6d41\u91cc\u51fa\u73b0 TERM \u5b57                       | TERM \u4e94\u5143\u7ec4\u9010\u5b57
//   5c \u65e0\u4e00\u5e27\u8d85\u8fc7 1514 \u5185\u5bb9\u5b57\u8282                         | \u6ce8\u5165\u6700\u957f\u5ea6
//   5d F4 \u4e22\u5e27\u8ba1\u6570 > 0                                   | \u540c 5a
//   5e \u6062\u590d\u540e\u4e0b\u4e00\u5e27\u9010\u5b57\u8282\u6b63\u786e                         | \u6ce8\u5165 64B, \u9996\u5b57\u8282 PAT[0]
//   6a TX \u7ebf\u4e0a\u6070 1 \u5e27 (\u65e0\u5e7d\u7075/\u65e0\u62c6\u5206)                      | \u6ce8\u5165 1 \u4e2a tlast \u5e27
//   6b TX \u9996\u5b57 /S/ \u5728 lane0                               | \u5382\u5546 :995/:1147-1149 + GATE1 \u00a7C.4
//   6c TX \u9996\u5b57\u5176\u4f59\u90e8\u5206 == 55\u00d76+D5                        | \u5382\u5546 :995 \u5b57\u9762\u91cf
//   6d/6e/6f TX \u7ebf\u4e0a\u524d\u5bfc\u4e0e\u5185\u5bb9\u7684 lane \u987a\u5e8f                | \u5408\u540c tdata[63:56] + \u6ce8\u5165\u5b57\u8282
//   7 W36..W50 = \u88ab force \u7684\u751f\u4ea7\u8005\u5e38\u91cf                    | force \u5728\u751f\u4ea7\u8005\u8282\u70b9
//   7b 0xEC \u8bfb 0 \u4e14 SLVERR (\u65e0\u56de\u7ed5)                        | axi_regs \u8bfb\u4fa7\u8bd1\u7801; 51 \u5b57\u5730\u56fe\u8fb9\u754c
// ---------------------------------------------------------------------------
'''
marker = '// ===========================================================================\nmodule tb_p7b_chain;'
assert s.count(marker) == 1
s = s.replace(marker, tbl + marker)

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('fix_tb2 done')
