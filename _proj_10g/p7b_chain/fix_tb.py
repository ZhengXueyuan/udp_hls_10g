# -*- coding: utf-8 -*-
"""Fix three defects found on review of tb_p7b_chain.v:
   1) the wire-content byte offsets were off by the 8-byte preamble word
   2) judgement 5c was VACUOUS (x >= 0 is always true) -> replaced by a real one
   3) missing parens around a && (===) expression
"""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

# 1) 6b / 6d / 6e
old = '''        chk("6b TX: first wire word has /S/ at lane0 (0xFB, c[0]=1)",
            (wq_d[0][7:0] === 8'hFB) && (wq_c[0][0] === 1'b1) === 1'b1,
            "vendor example :995/:1147-1149 + P7B_GATE1 C.4");'''
new = '''        chk("6b TX: first wire word has /S/ at lane0 (0xFB, c[0]=1)",
            ((wq_d[0][7:0] === 8'hFB) && (wq_c[0][0] === 1'b1)) === 1'b1,
            "vendor example :995/:1147-1149 + P7B_GATE1 C.4");'''
assert s.count(old) == 1, ('6b', s.count(old))
s = s.replace(old, new)

old = '''        if (wf_cnt == 1) begin
            chk("6d TX: content bytes are lane-ordered (no mirror)",
                (wf_b[0][0] === 8'h11) && (wf_b[0][1] === 8'h22) &&
                (wf_b[0][7] === 8'h88) === 1'b1,
                "tdata[63:56] is the first byte (contract); content[0]=0x11");
            chk("6e TX: 2nd content word is lane-ordered",
                (wf_b[0][8] === 8'h44) && (wf_b[0][15] === 8'h11) === 1'b1,
                "derived: tdata[63:56]=0x44 ... tdata[7:0]=0x11");
        end else begin
            chk("6d TX: content bytes are lane-ordered (SKIPPED: wf_cnt != 1)", 1'b0,
                "diagnostic gate");
            chk("6e TX: 2nd content word is lane-ordered (SKIPPED)", 1'b0, "diagnostic gate");
        end'''
new = '''        // ⚠️ 线上帧的 wf_b[0][0..6] = 0x55 x6, [7] = 0xD5 (帧首字余下的 lane),
        //    内容从 **wf_b[0][8]** 起 —— 偏移算错会让"内容判据"变成在比对前导。
        if (wf_cnt == 1) begin
            chk("6d TX: preamble in the wire frame == 55 x6 + D5",
                (wf_b[0][0] === 8'h55) && (wf_b[0][6] === 8'h55) &&
                (wf_b[0][7] === 8'hD5), "vendor example :995 literal");
            chk("6e TX: content bytes are lane-ordered (no mirror)",
                (wf_b[0][8] === 8'h11) && (wf_b[0][9] === 8'h22) &&
                (wf_b[0][15] === 8'h88), "contract: tdata[63:56] is the frame's first byte");
            chk("6f TX: 2nd content word is lane-ordered",
                (wf_b[0][16] === 8'h44) && (wf_b[0][23] === 8'h11),
                "derived: tdata[63:56]=0x44 ... tdata[7:0]=0x11");
        end else begin
            chk("6d TX: preamble in the wire frame (GATED OFF: wf_cnt != 1)", 1'b0,
                "diagnostic gate");
            chk("6e TX: content lane order (GATED OFF: wf_cnt != 1)", 1'b0,
                "diagnostic gate");
            chk("6f TX: 2nd content word lane order (GATED OFF)", 1'b0,
                "diagnostic gate");
        end'''
assert s.count(old) == 1, ('6de', s.count(old))
s = s.replace(old, new)

# 2) vacuous 5c -> real criterion (no delivered frame longer than 1514 content bytes)
old = '''        chk("5c no orphan bytes: \u03a3popc conservation still holds",
            (got_bytes + u_dut.rx_stat_orphan_bytes -
             (32'd40 * 32'd1514) + u_dut.rx_stat_orphan_bytes) >= 32'd0,
            "diagnostic (not a pass/fail criterion)");'''
new = '''        begin : no_overlong
            reg ok;
            ok = 1'b1;
            for (k = 0; k < got_f_cnt; k = k + 1)
                if (got_f_len[k] > 1514) ok = 1'b0;
            chk("5c every delivered frame is <= 1514 content bytes (no merge)",
                ok === 1'b1, "derived: max injected content length");
        end
        chk("5d F4 drop counters are monotone witnesses, not noise",
            (u_dut.rx_stat_drop_full + u_dut.rx_stat_drop_partial) > 32'd0,
            "40 x 1514B against a 16-word FIFO with tready=0");'''
assert s.count(old) == 1, ('5c', s.count(old))
s = s.replace(old, new)

# renumber the old 5d -> 5e (recovery check)
old = 'chk("5d recovery: the next frame is delivered byte-exact",'
assert s.count(old) == 1
s = s.replace(old, 'chk("5e recovery: the next frame is delivered byte-exact",')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('tb fixes applied')
