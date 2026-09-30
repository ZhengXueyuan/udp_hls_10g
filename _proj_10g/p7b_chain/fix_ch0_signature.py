# -*- coding: utf-8 -*-
"""2nd build failure: [Opt 31-67] a LUT2 inside the PCS core's channel-0 TX
encoder is missing an input connection -- because channel 0's status/control
OUTPUTS have no load at all in this wrapper, so Vivado trims their drivers and
the trim cascades into core-internal logic.

Remedy (the project's established trick, used in P7B_MAC_TIMING.md): XOR-fold
every unused channel-0 output into ONE signature bit and give that bit a real
load (it goes into the PCS status bundle's spare bit 30, i.e. snapshot W39[30]).
"""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/board/wrapper_p4.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

old = '''`ifdef P7B_10G
    // ---- PCS 状态位: 每位一个 2FF 进 dp 域 ----------------------------------'''
new = '''`ifdef P7B_10G
    // ---------------------------------------------------------------------
    // ch0 (= X0Y4 = J7, \u65e0\u7ebf) \u7684**\u5168\u90e8\u672a\u7528\u8f93\u51fa\u6298\u53e0\u6210\u4e00\u4e2a\u7b7e\u540d\u4f4d**
    //----------------------------------------------------------------------
    // \u26a0\u26a0 \u8fd9\u4e0d\u662f\u88c5\u9970: \u82e5 ch0 \u7684\u72b6\u6001/\u63a7\u5236\u8f93\u51fa**\u5b8c\u5168\u65e0\u8d1f\u8f7d**, Vivado \u4f1a\u4fee\u526a
    //   \u5b83\u4eec\u7684\u9a71\u52a8\u903b\u8f91, \u4fee\u526a\u4f1a\u8fde\u5e26\u6838\u5185\u903b\u8f91 \u21d2 \u672c\u8f6e\u5b9e\u6d4b\u4e24\u6b21\u90fd\u6b7b\u5728
    //   \u8fd9\u4e00\u7c7b\u4e0a:
    //     \u2460 [DRC MDRV-1] \u628a\u5b83\u4eec\u5168\u63a5\u5230\u540c\u4e00\u6839\u7ebf \u21d2 \u90a3\u6839\u7ebf ~12 \u4e2a\u9a71\u52a8\u6e90 (\u5df2\u4fee)
    //     \u2461 [Opt 31-67] \u5404\u81ea\u63a5\u72ec\u7acb\u7ebf\u4f46**\u65e0\u8d1f\u8f7d** \u21d2 \u6838\u5185
    //        `i_TX_ENCODER/is_valid_ctrl[3]_i_3` \u7684 I0 \u60ac\u7a7a (\u672c\u6b21\u4fee)
    //   \u4fee\u6cd5 = \u628a\u5b83\u4eec XOR \u6298\u53e0\u6210 1 \u4f4d, \u9001\u8fdb\u5feb\u7167\u7684**\u7a7a\u4f59\u4f4d W39[30]**
    //   \u21d2 \u771f\u5b9e\u8d1f\u8f7d + \u987a\u4fbf\u591a\u4e00\u4e2a\u53ef\u8bfb\u7684\u5065\u5eb7\u7b7e\u540d\u3002
    //   (\u540c\u624b\u6cd5\u5148\u4f8b: P7B_MAC_TIMING.md \u7684 `mtx_sig_hold`/`mrx_sig_hold` \u7b7e\u540d\u5bc4\u5b58\u5668\u3002)
    //----------------------------------------------------------------------
    wire pcs_ch0_sig = ^{pcs_ch0_u_ferr, pcs_ch0_u_ferrv, pcs_ch0_u_rlf, pcs_ch0_u_blk,
                        pcs_ch0_u_vcc,  pcs_ch0_u_status, pcs_ch0_u_ber, pcs_ch0_u_bad,
                        pcs_ch0_u_badv, pcs_ch0_u_errv,   pcs_ch0_u_fifo, pcs_ch0_u_tlf,
                        pcs_ch0_u_err,
                        pcs_user_rx_reset_0, pcs_user_tx_reset_0, pcs_gtpowergood_0,
                        pcs_rx_reset_0, pcs_tx_reset_0, gt_refclk_out_w, rxrecclkout_0};

    // ---- PCS 状态位: 每位一个 2FF 进 dp 域 ----------------------------------'''
assert s.count(old) == 1, ('anchor', s.count(old))
s = s.replace(old, new)

old2 = '''    assign pcs_status_bundle = {2'd0,
        pcs_gpw_sr[2], pcs_rtxrst_sr[2], pcs_ttxrst_sr[2], 5'd0,'''
assert s.count(old2) == 1, ('bundle', s.count(old2))
s = s.replace(old2, '''    assign pcs_status_bundle = {1'b0, pcs_ch0_sig,
        pcs_gpw_sr[2], pcs_rtxrst_sr[2], pcs_ttxrst_sr[2], 5'd0,''')

# bit-field comment update
old3 = '''    //   [31:30] 0 | [29] gtpowergood | [28] user_rx_reset | [27] user_tx_reset | [26:22] 0'''
assert s.count(old3) == 1
s = s.replace(old3, '''    //   [31] 0 | [30] **ch0 健康签名** (XOR \u6298\u53e0\u5168\u90e8 ch0 \u672a\u7528\u8f93\u51fa; \u5b83\u540c\u65f6\u662f
    //        "ch0 \u7684\u8f93\u51fa\u6709\u771f\u5b9e\u8d1f\u8f7d" \u7684\u7ed3\u6784\u4fdd\u8bc1 \u2014\u2014 \u89c1\u4e0a\u9762\u7684 MDRV-1/Opt 31-67 \u8bb0\u5f55)
    //      | [29] gtpowergood | [28] user_rx_reset | [27] user_tx_reset | [26:22] 0''')

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('ch0 signature added')
