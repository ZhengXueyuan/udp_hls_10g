# -*- coding: utf-8 -*-
"""Group-6 expectations were off by one preamble byte (the /S/ word contributes
SIX 0x55 then 0xD5 -- measured: wf_b = 55 55 55 55 55 55 D5 88 77 ...), and the
content byte order expectations were inverted relative to my own test vector
(tdata[63:56]=0x88 is the frame's FIRST byte).  Also add a raw W39 print."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

old = '''            chk("6d TX wf preamble",
                (wf_b[0][0] === 8'h55) && (wf_b[0][6] === 8'h55) &&
                (wf_b[0][7] === 8'hD5), "vendor :995 literal");
            chk("6e TX content lane order",
                (wf_b[0][8] === 8'h11) && (wf_b[0][9] === 8'h22) &&
                (wf_b[0][15] === 8'h88), "contract: tdata[63:56] 1st");
            chk("6f TX w2 lane order",
                (wf_b[0][16] === 8'h44) && (wf_b[0][23] === 8'h11),
                "derived: 0x44..0x11");'''
new = '''            // \u6d4b\u5f97\u7684\u7ebf\u4e0a\u5b57\u8282: 55 55 55 55 55 55 D5 | 88 77 66 55 44 33 22 11 | AA BB ...
            //   (\u9996\u5b57\u7684 lane0 \u662f /S/, lane1..6 = 0x55x6, lane7 = 0xD5;
            //    \u5185\u5bb9\u4ece\u7b2c 2 \u4e2a\u5b57\u7684 lane0 \u8d77 = wf_b[0][7])
            chk("6d TX wf preamble",
                (wf_b[0][0] === 8'h55) && (wf_b[0][5] === 8'h55) &&
                (wf_b[0][6] === 8'hD5), "vendor :995 literal (55x6+D5)");
            chk("6e TX content lane order",
                (wf_b[0][7] === 8'h88) && (wf_b[0][8] === 8'h77) &&
                (wf_b[0][14] === 8'h11), "contract: tdata[63:56]=0x88 is byte 0");
            chk("6f TX w2 lane order",
                (wf_b[0][15] === 8'hAA) && (wf_b[0][22] === 8'h44),
                "derived: tdata[63:56]=0xAA .. tdata[7:0]=0x44");'''
assert s.count(old) == 1, s.count(old)
s = s.replace(old, new)

old = '''            u_dut.snap_dout_all[36*32 +: 32], u_dut.snap_dout_all[50*32 +: 32],
            u_dut.snap_dout_all[37*32 +: 32], u_dut.snap_dout_all[38*32 +: 32]);'''
new = '''            u_dut.snap_dout_all[36*32 +: 32], u_dut.snap_dout_all[50*32 +: 32],
            u_dut.snap_dout_all[37*32 +: 32], u_dut.snap_dout_all[38*32 +: 32]);
        $display("  [DIAG7c] W39=%08h W40=%08h | blk_sr=%b gpw=%b vcc=%b rerr=%02h",
            u_dut.snap_dout_all[39*32 +: 32], u_dut.snap_dout_all[40*32 +: 32],
            u_dut.pcs_blk_sr, u_dut.pcs_gpw_sr[2], u_dut.pcs_vcc_sr[2], u_dut.pcs_rerr_sr[0]);'''
assert s.count(old) == 1
s = s.replace(old, new)

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('fix_tb4 done')
