# -*- coding: utf-8 -*-
"""Revert the FE/DP bundle extensions (the new words now live in the parallel
bundles) and the valid_fe gating."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/board/wrapper_p4.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

# 1) fe_src: drop the 3 added items at the head
i = s.find('    // ---- P7b: FE \u675f 14')
j = s.find('    assign fe_src = {rxcdc_ovf_cnt,')
k = s.find('                     rx_stat_fifo_ovf,')
assert 0 < i < j < k, (i, j, k)
s = s[:j] + '    assign fe_src = {rx_stat_fifo_ovf,' + s[k + len('                     rx_stat_fifo_ovf,'):]
assert s.count('    assign fe_src = {rx_stat_fifo_ovf,') == 1

# 2) dp_src: drop the 12 added items at the head
i = s.find('    // ---- P7b: DP \u675f 22')
j = s.find('    assign dp_src = {tx_clk_act,')
k = s.find('                     rxcdc_out_bytes,         // W31')
assert 0 < i < j < k, (i, j, k)
s = s[:j] + '    assign dp_src = {rxcdc_out_bytes,         // W31' + \
    s[k + len('                     rxcdc_out_bytes,         // W31'):]
assert s.count('    assign dp_src = {rxcdc_out_bytes,') == 1

# 3) valid_fe gating revert
k = s.find('        // \u26a0\ufe0f P7b: `valid_fe` \u8d70\u7684\u662f `valid_fe_gated`')
k2 = s.find('        .req_fe     (req_fe),   .busy_fe(busy_fe), .valid_fe(valid_fe_gated), .dout_fe(fe_dout),')
assert 0 < k < k2, (k, k2)
s = s[:k] + s[k2:].replace(
    '        .req_fe     (req_fe),   .busy_fe(busy_fe), .valid_fe(valid_fe_gated), .dout_fe(fe_dout),',
    '        .req_fe     (req_fe),   .busy_fe(busy_fe), .valid_fe(valid_fe), .dout_fe(fe_dout),', 1)
assert 'valid_fe_gated' not in s, 'valid_fe_gated still present'

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('reverted OK')
