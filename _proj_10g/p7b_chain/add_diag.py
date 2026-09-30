# -*- coding: utf-8 -*-
"""Add a DIAG dump (called after group 1 and group 6) so the first-run failures
can be attributed instead of guessed at."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

task = '''    task diag;
        input [127:0] tag;
        begin
            $display("  [DIAG] %0s xq_wr=%0d xq_rd=%0d | rx_words=%0d rx_frames=%0d rx_state=%0d crc=%0d drop=%0d df=%0d dp=%0d orph=%0d | rxsrc_v=%b rx_v=%b rx_rdy=%b | rxcdc_occ=%0d | txfr=%0d tx_state=%0d txsrc_v=%b mtx_v=%b txcdc_occ=%0d wq=%0d",
                tag, xq_wr, xq_rd,
                u_dut.mrx_stat_rx_words, u_dut.rx_stat_frames, u_dut.mrx_dbg_state,
                u_dut.rx_stat_crc_err, u_dut.rx_stat_drop,
                u_dut.rx_stat_drop_full, u_dut.rx_stat_drop_partial,
                u_dut.rx_stat_orphan_bytes,
                u_dut.rxsrc_tvalid, u_dut.rx_tvalid, u_dut.rx_tready,
                u_dut.rxcdc_occ_w,
                u_dut.mac_tx_frames, u_dut.mtx_dbg_state,
                u_dut.txsrc_tvalid, u_dut.m_tx_tvalid, u_dut.txcdc_occ_w, wq_wr);
        end
    endtask

'''
marker = '    // ======================= \u4e3b\u6d41\u7a0b'
assert s.count(marker) == 1
s = s.replace(marker, task + marker)

old = '''        chk("1c RX first byte is NOT the XGMII lane7 byte (would be PAT[7] if mis-mirrored)",
            (got_first_tdata[63:56] !== PAT[7]) === 1'b1,
            "negative: distinct first 8 content bytes");'''
new = old + '''
        diag("after-group1");'''
assert s.count(old) == 1
s = s.replace(old, new)

old = '''        chk("6c TX: preamble = 0x55 x6 + 0xD5 in the rest of the first word",
            (wq_d[0][63:8] === 56'hD5555555555555) === 1'b1,
            "vendor example :995 literal");'''
assert s.count(old) == 1
new = old + '''
        diag("after-group6");'''
s = s.replace(old, new)

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('diag added')
