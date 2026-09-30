# -*- coding: utf-8 -*-
"""ROOT CAUSE of the 3rd build stop (Opt 31-67 / 100x Opt 31-155), now found by
reading the wrapper instead of guessing:

  `assign tx_mii_d_0 = 64'h0707...07;  assign tx_mii_c_0 = 8'hFF;` were DELETED
  by an earlier edit of mine (the one that de-duplicated the SFP TX_DIS assigns).
  An undriven output port is legal Verilog and the chain gate does not observe
  channel 0, so nothing caught it -- but Vivado then reports the PCS-internal
  copies of that port as DRIVERLESS nets:
      WARNING: [Opt 31-155] Driverless net .../i_TX_ENCODER/tx_mii_d[36] ...
      ERROR:   [Opt 31-67] ... i_TX_ENCODER/is_valid_ctrl[3]_i_3 ... missing I0

Restore them -- this time in a `dont_touch` register (the value is the same
legal 10GBASE-R IDLE, but the core sees real nets rather than a constant that
opt could fold away, which is the other way this same LUT family can go bad).
"""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/board/wrapper_p4.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()

anchor = "    //   RX \u7531 mac_rx_10g \u6d88\u8d39 rx_mii_d/c_1 (\u4e0b\u9762); ch0 \u6052 IDLE\u3002\n"
assert s.count(anchor) == 1, ('anchor', s.count(anchor))

NEW = (
"    //   RX \u7531 mac_rx_10g \u6d88\u8d39 rx_mii_d/c_1 (\u4e0b\u9762)\u3002\n"
"    //\n"
"    // ch0 (= X0Y4 = J7, \u65e0\u7ebf) \u53d1\u5e38\u91cf IDLE \u6d41\u3002\n"
"    //   \u26a0\u26a0 \u8fd9\u4e24\u884c\u66fe\u88ab\u4e00\u6b21\u7f16\u8f91**\u8bef\u5220** (\u53bb\u91cd SFP TX_DIS \u7684\u90a3\u6b21)\u3002\n"
"    //   \u65e0\u9a71\u52a8\u7684\u8f93\u51fa\u7aef\u662f\u5408\u6cd5 Verilog, \u800c ch0 \u53c8\u4e0d\u5728\u4efb\u4f55\u5224\u636e\u91cc\n"
"    //   \u21d2 \u6ca1\u6709\u95e8\u62a5\u8b66; \u4f46 Vivado \u4f1a\u628a\u6838\u5185\u90a3\u4e2a\u7aef\u53e3\u7684\u526f\u672c\u62a5\u6210\n"
"    //   **Driverless net** \u5e76\u5728 opt_design \u5347\u7ea7\u6210\u9519:\n"
"    //     WARNING: [Opt 31-155] Driverless net .../i_TX_ENCODER/tx_mii_d[36] ...\n"
"    //     ERROR:   [Opt 31-67] ... i_TX_ENCODER/is_valid_ctrl[3]_i_3 ... missing I0\n"
"    //   \u4fee\u6cd5: \u6062\u590d\u4e3a `dont_touch` \u5bc4\u5b58\u5668 (\u503c\u4e0d\u53d8 = \u5408\u6cd5 10GBASE-R idle,\n"
"    //   \u4f46\u6838\u770b\u5230\u7684\u662f\u771f\u7f51\u800c\u975e\u53ef\u88ab\u5e38\u91cf\u6298\u53e0\u7684\u5b57\u9762\u91cf \u2014\u2014 \u540c\u4e00\u7c7b LUT \u8fd8\u6709\n"
"    //   \u53e6\u4e00\u6761\u51fa\u9519\u8def\u5f84\u5c31\u662f\u5b83)\u3002\n"
"    (* dont_touch = \"true\" *) reg [63:0] p7b_ch0_idle_d;\n"
"    (* dont_touch = \"true\" *) reg [7:0]  p7b_ch0_idle_c;\n"
"    always @(posedge tx_mii_clk_0) begin\n"
"        p7b_ch0_idle_d <= 64'h0707070707070707;   // \u5168 lane /I/\n"
"        p7b_ch0_idle_c <= 8'hFF;\n"
"    end\n"
"    assign tx_mii_d_0 = p7b_ch0_idle_d;\n"
"    assign tx_mii_c_0 = p7b_ch0_idle_c;\n"
)
s = s.replace(anchor, NEW)
io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('ch0 TX idle restored (dont_touch register)')
