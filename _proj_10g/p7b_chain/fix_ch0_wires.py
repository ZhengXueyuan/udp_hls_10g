# -*- coding: utf-8 -*-
"""Fix [DRC MDRV-1]: channel 0's unused PCS status OUTPUTS were all tied to ONE
net (`pcs_ch0_unused`) -> that net has ~12 drivers, and opt_design refuses.
Give every output its own wire (each then has exactly one driver).

Measured: ERROR: [DRC MDRV-1] Multiple Driver Nets: Net
u_pcs/inst/i_pcs64_top_0/stat_rx_status_0 has multiple drivers: ... (12 cells)
"""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/board/wrapper_p4.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

old = '''    // ch0 未用的控制/状态: 悬空会让核内读它们的 LUT 悬空 (侦察期 opt_design 直接失败)
    wire        pcs_ch0_unused;
    wire [7:0]  pcs_ch0_unused8;
    wire [57:0] pcs_ch0_unused58;'''
new = '''    // ch0 未用的控制/状态
    //   \u26a0\u26a0 **\u6bcf\u4e2a\u8f93\u51fa\u5fc5\u987b\u6709\u81ea\u5df1\u7684\u7ebf** \u2014\u2014 \u628a\u5b83\u4eec\u63a5\u5230\u540c\u4e00\u6839 `pcs_ch0_unused`
    //   \u4f1a\u8ba9\u90a3\u6839\u7ebf\u6709 ~12 \u4e2a\u9a71\u52a8\u6e90 \u21d2 opt_design \u62a5
    //     [DRC MDRV-1] Multiple Driver Nets: Net u_pcs/inst/i_pcs64_top_0/stat_rx_status_0
    //     has multiple drivers: ... (\u672c\u8f6e\u5b9e\u6d4b\uff0c\u5efa\u6784\u76f4\u63a5\u6b7b\u5728 opt_design)
    //   \u8f93\u5165\u7aef\u5171\u7528\u4e00\u6839\u5e38\u91cf\u7ebf\u662f\u5408\u6cd5\u7684 (\u591a\u4e2a\u8f93\u5165\u7aef\u53ef\u4ee5\u540c\u6e90)\u3002
    wire        pcs_ch0_u_ferr, pcs_ch0_u_ferrv, pcs_ch0_u_rlf, pcs_ch0_u_blk;
    wire        pcs_ch0_u_vcc, pcs_ch0_u_status, pcs_ch0_u_ber, pcs_ch0_u_bad;
    wire        pcs_ch0_u_badv, pcs_ch0_u_errv, pcs_ch0_u_fifo, pcs_ch0_u_tlf;
    wire [7:0]  pcs_ch0_u_err;
    wire [57:0] pcs_ch0_unused58;'''
assert s.count(old) == 1, ('decl', s.count(old))
s = s.replace(old, new)

# remap the ch0 output connections one by one
pairs = [
 ('.stat_rx_framing_err_0            (pcs_ch0_unused),', '.stat_rx_framing_err_0            (pcs_ch0_u_ferr),'),
 ('.stat_rx_framing_err_valid_0      (pcs_ch0_unused),', '.stat_rx_framing_err_valid_0      (pcs_ch0_u_ferrv),'),
 ('.stat_rx_local_fault_0            (pcs_ch0_unused),', '.stat_rx_local_fault_0            (pcs_ch0_u_rlf),'),
 ('.stat_rx_block_lock_0             (pcs_ch0_unused),', '.stat_rx_block_lock_0             (pcs_ch0_u_blk),'),
 ('.stat_rx_valid_ctrl_code_0        (pcs_ch0_unused),', '.stat_rx_valid_ctrl_code_0        (pcs_ch0_u_vcc),'),
 ('.stat_rx_status_0                 (pcs_ch0_unused),', '.stat_rx_status_0                 (pcs_ch0_u_status),'),
 ('.stat_rx_hi_ber_0                 (pcs_ch0_unused),', '.stat_rx_hi_ber_0                 (pcs_ch0_u_ber),'),
 ('.stat_rx_bad_code_0               (pcs_ch0_unused),', '.stat_rx_bad_code_0               (pcs_ch0_u_bad),'),
 ('.stat_rx_bad_code_valid_0         (pcs_ch0_unused),', '.stat_rx_bad_code_valid_0         (pcs_ch0_u_badv),'),
 ('.stat_rx_error_0                  (pcs_ch0_unused8),', '.stat_rx_error_0                  (pcs_ch0_u_err),'),
 ('.stat_rx_error_valid_0            (pcs_ch0_unused),', '.stat_rx_error_valid_0            (pcs_ch0_u_errv),'),
 ('.stat_rx_fifo_error_0             (pcs_ch0_unused),', '.stat_rx_fifo_error_0             (pcs_ch0_u_fifo),'),
 ('.stat_tx_local_fault_0            (pcs_ch0_unused),', '.stat_tx_local_fault_0            (pcs_ch0_u_tlf),'),
]
for a, b in pairs:
    assert s.count(a) == 1, (a, s.count(a))
    s = s.replace(a, b)
assert 'pcs_ch0_unused)' not in s and 'pcs_ch0_unused8' not in s
io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('ch0 wires split OK')
