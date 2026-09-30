# -*- coding: utf-8 -*-
"""Fix the snapshot bus: `wire [31:0] x [0:n]` (unpacked array of wires) driven by
a port connection to a concatenation reads **z** in xsim (measured: DIAG7b showed
r36/r37/r38/r50 = zzzzzzzz while all three `seen` flags were 1).  Replace the
three unpacked arrays with plain packed vectors + `+: ` slices."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()
W = 'D:/repo/XCKU5PMini/udp_hls_10g/board/wrapper_p4.v'
w = io.open(W, 'r', encoding='utf-8', newline='').read()

# ---- wrapper: packed vectors -------------------------------------------------
old = '''    wire [31:0] p7bfe_dout [0:2];
    wire [31:0] p7bdp_dout [0:11];
    wire [31:0] txsnap_dout [0:3];'''
new = '''    // \u26a0\ufe0f \u7528**\u6253\u5305\u5411\u91cf**\u800c\u4e0d\u662f wire \u7684\u975e\u6253\u5305\u6570\u7ec4: \u540e\u8005\u8fde\u5230
    //    \u7aef\u53e3\u7684\u62fc\u63a5\u4e0a\u5728 xsim \u91cc**\u8bfb\u56de z** (\u672c\u95e8\u5b9e\u6d4b: seen \u5168 1 \u800c
    //    dout \u5168 z) \u2014\u2014 \u8fd9\u79cd\u9519\u53ea\u6709\u9010\u5b57\u8bfb\u56de\u7684\u95e8\u80fd\u6293\u3002
    wire [95:0]  p7bfe_dout;    // [2:0] \u2192 \u69fd 0/1/2
    wire [383:0] p7bdp_dout;    // [11:0] \u2192 \u69fd 0..11
    wire [127:0] txsnap_dout;   // [3:0]  \u2192 \u69fd 0..3'''
assert w.count(old) == 1, ('wdecl', w.count(old))
w = w.replace(old, new)

old = '''        .dout_a({p7bfe_dout[2], p7bfe_dout[1], p7bfe_dout[0]}),
        .valid_a(p7bfe_valid), .clk_b(gmii_clk), .din_b(p7bfe_din)'''
assert w.count(old) == 1
w = w.replace(old, old)   # port connection stays the same (concat of slices)

old = '''        .dout_a({p7bdp_dout[11], p7bdp_dout[10], p7bdp_dout[9], p7bdp_dout[8],
                 p7bdp_dout[7],  p7bdp_dout[6],  p7bdp_dout[5], p7bdp_dout[4],
                 p7bdp_dout[3],  p7bdp_dout[2],  p7bdp_dout[1], p7bdp_dout[0]}),'''
assert w.count(old) == 1
w = w.replace(old, '        .dout_a(p7bdp_dout),')

old = '''        .dout_a({txsnap_dout[3], txsnap_dout[2], txsnap_dout[1], txsnap_dout[0]}),'''
assert w.count(old) == 1
w = w.replace(old, '        .dout_a(txsnap_dout),')

old = '''        .dout_a({p7bfe_dout[2], p7bfe_dout[1], p7bfe_dout[0]}),'''
assert w.count(old) == 1
w = w.replace(old, '        .dout_a(p7bfe_dout),')

old = '''        p7bdp_dout[11],   // W50 tx_mii_clk \u6d3b\u6027 (toggle \u6cbf\u8ba1\u6570)
        p7bdp_dout[10],   // W49 rx_classify \u5b57 FIFO \u5f53\u524d\u5360\u7528
        p7bdp_dout[9],    // W48 rx_classify \u8f93\u5165\u505c\u7b49\u62cd\u6570
        p7bdp_dout[8],    // W47 rx_classify \u8def\u7531\u961f\u5217\u62d2\u5199 (\u6052 0)
        p7bdp_dout[7],    // W46 rx_classify \u5b57 FIFO \u62d2\u5199   (\u6052 0)
        p7bdp_dout[6],    // W45 u_txcdc \u62d2\u5199 (wr \u57df = DP)
        txsnap_dout[3],   // W44 mac_tx_10g.stat_tx_ctrl_char
        txsnap_dout[2],   // W43 mac_tx_10g.stat_tx_words
        txsnap_dout[1],   // W42 mac_tx_10g.stat_flush_done
        txsnap_dout[0],   // W41 mac_tx_10g.stat_flush_words
        p7bdp_dout[5],    // W40 PCS \u4e8b\u4ef6\u675f
        p7bdp_dout[4],    // W39 PCS \u72b6\u6001\u675f
        p7bfe_dout[2],    // W38 u_rxcdc \u62d2\u5199 (wr \u57df = FE)
        p7bfe_dout[1],    // W37 mac_rx_10g \u03a3popc(tkeep) \u5df2\u4ea4\u4ed8
        p7bfe_dout[0],    // W36 mac_rx_10g XGMII \u5b57\u6570 (\u901f\u7387\u6b63\u8bc1\u636e)'''
new = '''        p7bdp_dout[11*32 +: 32],   // W50 tx_mii_clk \u6d3b\u6027 (toggle \u6cbf\u8ba1\u6570)
        p7bdp_dout[10*32 +: 32],   // W49 rx_classify \u5b57 FIFO \u5f53\u524d\u5360\u7528
        p7bdp_dout[9*32 +: 32],    // W48 rx_classify \u8f93\u5165\u505c\u7b49\u62cd\u6570
        p7bdp_dout[8*32 +: 32],    // W47 rx_classify \u8def\u7531\u961f\u5217\u62d2\u5199 (\u6052 0)
        p7bdp_dout[7*32 +: 32],    // W46 rx_classify \u5b57 FIFO \u62d2\u5199   (\u6052 0)
        p7bdp_dout[6*32 +: 32],    // W45 u_txcdc \u62d2\u5199 (wr \u57df = DP)
        txsnap_dout[3*32 +: 32],   // W44 mac_tx_10g.stat_tx_ctrl_char
        txsnap_dout[2*32 +: 32],   // W43 mac_tx_10g.stat_tx_words
        txsnap_dout[1*32 +: 32],   // W42 mac_tx_10g.stat_flush_done
        txsnap_dout[0*32 +: 32],   // W41 mac_tx_10g.stat_flush_words
        p7bdp_dout[5*32 +: 32],    // W40 PCS \u4e8b\u4ef6\u675f
        p7bdp_dout[4*32 +: 32],    // W39 PCS \u72b6\u6001\u675f
        p7bfe_dout[2*32 +: 32],    // W38 u_rxcdc \u62d2\u5199 (wr \u57df = FE)
        p7bfe_dout[1*32 +: 32],    // W37 mac_rx_10g \u03a3popc(tkeep) \u5df2\u4ea4\u4ed8
        p7bfe_dout[0*32 +: 32],    // W36 mac_rx_10g XGMII \u5b57\u6570 (\u901f\u7387\u6b63\u8bc1\u636e)'''
assert w.count(old) == 1, ('wassemble', w.count(old))
w = w.replace(old, new)
io.open(W, 'w', encoding='utf-8', newline='').write(w)

# ---- TB: print the decoded wire-frame head (group 6 attribution) -------------
marker = '''        begin : tx_w0'''
assert s.count(marker) == 1
s = s.replace(marker, '''        $display("  [DIAG6] wf_cnt=%0d wf_n0=%0d b=%02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
            wf_cnt, (wf_cnt > 0) ? wf_n[0] : -1,
            wf_b[0][0], wf_b[0][1], wf_b[0][2], wf_b[0][3], wf_b[0][4], wf_b[0][5],
            wf_b[0][6], wf_b[0][7], wf_b[0][8], wf_b[0][9], wf_b[0][10], wf_b[0][11],
            wf_b[0][12], wf_b[0][13], wf_b[0][14], wf_b[0][15]);
''' + marker)

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('fix_tb3 done')
