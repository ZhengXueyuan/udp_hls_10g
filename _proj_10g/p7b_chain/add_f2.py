# -*- coding: utf-8 -*-
"""Add group 8 to the chain gate: F-2 (frame abort) judged on **wire content
frame by frame**, not on counters -- the project measured that the flush counters
can be spoofed (P6B_CDC_AUDIT B8 / the rxcls M7b mutation).

Sequence: force 2 words of frame A then stop (no TLAST) -> mac_tx_10g aborts and
flushes; then force a complete frame B.  Expectations:
  8a  exactly 2 wire frames (a ghost frame would make it 3)
  8b  the LAST wire frame's first 8 content bytes == B's 8 bytes (byte-exact)
  8c  the LAST wire frame's content length == 60 (pad to MIN_CLEN; no A bytes mixed in)
  8d  the FIRST wire frame's content is a PREFIX of A's bytes (legal runt)
"""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

anchor = '        // -------- \u7b2c 7 \u7ec4: \u5feb\u7167 51 \u5b57\u9010\u5b57\u8bfb\u56de ------------------------------'
assert s.count(anchor) == 1, s.count(anchor)

G8 = r'''        // -------- \u7b2c 8 \u7ec4: F-2 (\u5e27\u5185\u65ad\u4f9b \u21d2 \u51b2\u5237) \u2014\u2014 \u5224\u636e = **\u7ebf\u4e0a\u5185\u5bb9\u9010\u5e27**
        //   \u26a0\ufe0f \u4e3a\u4ec0\u4e48\u4e0d\u80fd\u53ea\u770b\u8ba1\u6570\u5668: \u672c\u5de5\u7a0b\u5b9e\u6d4b\u8fc7\u8ba1\u6570\u5668\u53ef\u4ee5\u88ab\u4f2a\u88c5
        //   (rxcls \u53d8\u5f02 M7b: \u53bb\u51b2\u5237 + \u8ba1\u6570\u5668 +1 \u21d2 \u65e7\u95e8 229/0 \u901a\u8fc7, \u800c\u7ebf\u4e0a\u771f\u51fa\u4e86 172B \u5e7d\u7075\u5e27)\u3002
        //   A = 2 \u4e2a\u5b57\u540e\u65ad\u4f9b (\u65e0 TLAST) \u21d2 mac_tx_10g \u5e27\u5185\u4e2d\u6b62; B = \u5b8c\u6574\u4e00\u5e27\u3002
        wq_wr = 0;
        force u_dut.txsrc_tdata = 64'h88776655_44332211;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b0;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tdata = 64'h00000000_00000000;
        force u_dut.txsrc_tkeep = 8'hFF;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tvalid = 1'b0;      // \u65ad\u4f9b (\u6ca1\u6709 TLAST)
        repeat (600) @(posedge u_dut.dp_clk);
        repeat (400) @(posedge u_dut.tx_mii_clk_1);
        // frame B: \u4e00\u4e2a\u5b57 + TLAST
        force u_dut.txsrc_tdata = 64'hAABBCCDD_11223344;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b1;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tvalid = 1'b0;
        repeat (800) @(posedge u_dut.dp_clk);
        repeat (800) @(posedge u_dut.tx_mii_clk_1);
        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;
        decode_wire(6000);
        begin : f2
            integer f, nb, nm;
            reg ok_prefix, ok_b;
            ok_prefix = 1'b1; ok_b = 1'b0; nb = 0;
            for (f = 0; f < 32; f = f + 1) begin
                nm = wf_n[f];
                if (f < wf_cnt) begin
                    // \u5185\u5bb9 = \u524d\u5bfc\u4e4b\u540e\u7684\u5b57\u8282; A \u7684\u5b57\u8282 = 88 77 66 55 44 33 22 11
                    if (nm > 7) begin
                        if ((nm - 7) > 8) ok_prefix = 1'b0;
                        else if (wf_b[f][7] !== 8'h88) ok_prefix = 1'b0;
                        else begin
                            if ((nm - 7) > 1 && wf_b[f][8]  !== 8'h77) ok_prefix = 1'b0;
                            if ((nm - 7) > 2 && wf_b[f][9]  !== 8'h66) ok_prefix = 1'b0;
                            if ((nm - 7) > 3 && wf_b[f][10] !== 8'h55) ok_prefix = 1'b0;
                        end
                    end
                    // \u6700\u540e\u4e00\u5e27\u5fc5\u987b\u662f B
                    if (f == wf_cnt - 1) begin
                        if ((nm - 7) >= 8 &&
                            wf_b[f][7]  === 8'hAA && wf_b[f][8]  === 8'hBB &&
                            wf_b[f][9]  === 8'hCC && wf_b[f][10] === 8'hDD &&
                            wf_b[f][11] === 8'h11 && wf_b[f][12] === 8'h22 &&
                            wf_b[f][13] === 8'h33 && wf_b[f][14] === 8'h44) ok_b = 1'b1;
                        nb = nm - 7;      // \u5185\u5bb9\u5b57\u8282\u6570 (\u542b pad + FCS)
                    end
                end
            end
            $display("  [DIAG8] wf_cnt=%0d last_content_len=%0d prefix_ok=%b b_ok=%b",
                     wf_cnt, nb, ok_prefix, ok_b);
            // 8a: \u7ebf\u4e0a\u5e27\u6570 \u2014\u2014 \u65ad\u4f9b\u4e00\u5e27\u7684 runt + \u5b8c\u6574\u7684 B = 2 (\u65e0\u5e7d\u7075\u5c31\u662f 2)
            chk("8a F-2 wire frames == 2", (wf_cnt === 2) === 1'b1,
                "derived: 1 runt + 1 complete frame");
            // 8b: \u6bcf\u4e00\u5e27\u8981\u4e48\u662f A \u7684\u524d\u7f00, \u8981\u4e48\u5c31\u662f B (\u65e0\u5176\u5b83\u53ef\u80fd)
            chk("8b every wire frame is A-prefix or B", (ok_prefix === 1'b1) === 1'b1,
                "content compare, NOT counters");
            // 8c: \u6700\u540e\u4e00\u5e27 == B \u9010\u5b57\u8282
            chk("8c post-flush frame == B byte-exact", (ok_b === 1'b1) === 1'b1,
                "derived: B = AA BB CC DD 11 22 33 44");
            // 8d: B \u88ab pad \u5230 MIN_CLEN (\u5185\u5bb9 60B) + FCS 4B = 64B \u7ebf\u4e0a\u5185\u5bb9
            chk("8d post-flush frame content == 60B (pad) + 4B FCS",
                (nb === 64) === 1'b1, "mac_tx_10g: ETH_MIN_CLEN = 60");
        end

'''
s = s.replace(anchor, G8 + anchor)
io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('group 8 (F-2) added')
